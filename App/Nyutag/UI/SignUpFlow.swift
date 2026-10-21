// Нютаг. Регистрация: одна форма (имя, телефон, почта, пароль), затем код из письма. Что обязательно и нужен ли
// код приглашения, решает сервер (`/_nyutag/v1/config`); ник для Matrix ID получаем из имени и сверяем с сервером.

import Foundation
import NyutagCore
import Observation

@MainActor @Observable
final class SignUpFlow {
    enum Failure: Error, Equatable {
        case phoneTaken, emailTaken, badPhone, badEmail, nickTaken, badNick, weakPassword
        case badInvite, inviteUsed, wrongCode, codeExpired, tooManyTries, tooOften, mailFailed, noNetwork, broken
    }

    enum Nick: Equatable { case empty, checking, free, taken, invalid }

    private(set) var configuration: SignUpConfiguration?
    private(set) var nick = ""
    private(set) var nickState: Nick = .empty
    /// Ник набран руками: имя его больше не перезаписывает.
    private(set) var nickTyped = false
    /// Письмо с кодом ушло: на этот адрес и с этим номером продолжаем.
    private(set) var verification: Verification?
    private(set) var sentAt: Date?
    private(set) var phone: String?

    @ObservationIgnored private var nickCheck: Task<Void, Never>?

    var needsInvite: Bool { configuration?.requiresInvite ?? false }

    private func service() -> NyutagService { NyutagService(client: TunnelHub.shared.makeClient()) }

    func prepare() async {
        guard configuration == nil, await TunnelHub.shared.waitUntilUp() else { return }
        configuration = try? await service().configuration()
    }

    // MARK: Ник

    /// Имя поменялось: ник следует за ним, пока человек не набрал свой.
    func nameChanged(_ name: String) {
        guard !nickTyped else { return }
        propose(Nickname.from(name: name), typed: false)
    }

    func nickEdited(_ typed: String) {
        nickTyped = !typed.isEmpty
        propose(Nickname.clean(typed), typed: true)
    }

    private func propose(_ candidate: String, typed: Bool) {
        nickCheck?.cancel()
        nick = candidate
        guard !candidate.isEmpty else { nickState = .empty; return }
        guard Nickname.isValid(candidate) else { nickState = .invalid; return }
        nickState = .checking
        nickCheck = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self else { return }
            let client = TunnelHub.shared.makeClient()
            guard await TunnelHub.shared.waitUntilUp() else { return }
            if (try? await client.isUsernameAvailable(candidate)) == true {
                if !Task.isCancelled { nickState = .free }
                return
            }
            // Ник из имени занят — тихо берём свободный вариант с цифрами; свой набранный ник не трогаем.
            if !typed {
                for other in Nickname.alternatives(for: candidate) where !Task.isCancelled {
                    if (try? await client.isUsernameAvailable(other)) == true {
                        nick = other
                        nickState = .free
                        return
                    }
                }
            }
            if !Task.isCancelled { nickState = .taken }
        }
    }

    // MARK: Код из письма

    /// Номер свободен, письмо с кодом ушло на почту.
    func sendCode(phone typedPhone: String, email: String, invite: String) async throws(Failure) {
        guard await TunnelHub.shared.waitUntilUp() else { throw .noNetwork }
        let service = service()
        do {
            let trimmed = typedPhone.trimmingCharacters(in: .whitespaces)
            phone = trimmed.isEmpty ? nil : try await service.checkPhone(trimmed, inviteCode: invite)
        } catch {
            throw Self.failure(error, contact: .msisdn)
        }
        do {
            verification = try await service.startVerification(medium: .email, address: email.trimmingCharacters(in: .whitespaces),
                                                               inviteCode: invite)
            sentAt = .now
        } catch {
            throw Self.failure(error, contact: .email)
        }
    }

    /// Можно ли уже попросить письмо заново.
    func canResend(at now: Date) -> Bool {
        guard let sentAt, let verification else { return false }
        return now.timeIntervalSince(sentAt) >= Double(verification.resendAfter.components.seconds)
    }

    func forgetCode() {
        verification = nil
        sentAt = nil
    }

    /// Код верный — заводим аккаунт и сразу входим; имя уходит в профиль.
    func finish(token: String, name: String, password: String, invite: String,
                session: AppSession) async throws(Failure) {
        guard let verification else { throw .codeExpired }
        let service = service()
        let userID: String
        do {
            guard try await service.checkVerification(sid: verification.sid, token: token) else { throw Failure.wrongCode }
            userID = try await service.register(code: invite, username: nick, password: password, sid: verification.sid,
                                                phone: phone)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Self.failure(error, contact: .email)
        }
        do throws(AppSession.SignInFailure) {
            try await session.signIn(identifier: userID, password: password,
                                     displayName: name.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            throw error == .tooOften ? .tooOften : .noNetwork
        }
    }

    static func failure(_ error: any Error, contact: ContactMedium) -> Failure {
        guard let error = error as? MatrixError else { return .broken }
        switch error.errcode {
        case "NYUTAG_CONTACT_IN_USE": return contact == .email ? .emailTaken : .phoneTaken
        case "NYUTAG_BAD_CONTACT": return contact == .email ? .badEmail : .badPhone
        case "M_USER_IN_USE": return .nickTaken
        case "M_INVALID_USERNAME": return .badNick
        case "M_WEAK_PASSWORD": return .weakPassword
        case "NYUTAG_BAD_CODE", "NYUTAG_UNKNOWN_CODE": return .badInvite
        case "NYUTAG_CODE_USED", "NYUTAG_CODE_EXPIRED": return .inviteUsed
        case "NYUTAG_VERIFY_WRONG": return .wrongCode
        case "NYUTAG_VERIFY_EXPIRED", "NYUTAG_UNKNOWN_SESSION", "NYUTAG_CONTACT_NOT_VERIFIED": return .codeExpired
        case "NYUTAG_VERIFY_ATTEMPTS": return .tooManyTries
        case "M_LIMIT_EXCEEDED": return .tooOften
        case "NYUTAG_DELIVERY_FAILED", "NYUTAG_CHANNEL_UNAVAILABLE": return .mailFailed
        default: break
        }
        if error.status == 429 { return .tooOften }
        switch error.kind {
        case .network, .cancelled: return .noNetwork
        default: return .broken
        }
    }
}
