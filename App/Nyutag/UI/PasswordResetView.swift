// Нютаг. «Забыли пароль?»: код приходит на почту, к которой привязан аккаунт; с кодом задаётся новый пароль,
// и приложение сразу входит. Прочие устройства сервер при сбросе не выводит: пароль просто сменится.

import NyutagCore
import SwiftUI

struct PasswordResetView: View {
    @Environment(Words.self) private var words
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var code = ""
    @State private var password = ""
    @State private var verification: Verification?
    @State private var sentAt: Date?
    @State private var busy = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if verification == nil { addressStep } else { codeStep }
                    if let failure { FailureNote(text: failure) }
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.milk.ignoresSafeArea())
            .navigationTitle(words(.resetTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(words(.cancel)) { dismiss() } }
            }
            #if DEBUG
            .task { await fillForScreenshots() }
            #endif
        }
    }

    @ViewBuilder private var addressStep: some View {
        Text(words(.resetLead)).foregroundStyle(Theme.ink)
        TextField(words(.email), text: $email)
            .keyboardType(.emailAddress)
            .textContentType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(16)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .accessibilityIdentifier("reset-email")
        BigButton(title: words(.resetSend), busy: busy, enabled: !busy && email.contains("@"), id: "reset-send") {
            Task { await send() }
        }
    }

    @ViewBuilder private var codeStep: some View {
        Text(words(.codeSent, email.trimmingCharacters(in: .whitespaces))).foregroundStyle(Theme.ink)
        VStack(spacing: 0) {
            TextField("000000", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .font(.system(size: 28, weight: .semibold, design: .monospaced))
                .multilineTextAlignment(.center)
                .onChange(of: code) {
                    let digits = String(code.filter(\.isNumber).prefix(6))
                    if digits != code { code = digits }
                }
                .padding(16)
                .accessibilityIdentifier("reset-code")
            Divider().padding(.leading, 16)
            SecureField(words(.resetNewPassword), text: $password)
                .textContentType(.newPassword)
                .padding(16)
                .accessibilityIdentifier("reset-password")
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        BigButton(title: words(.resetSubmit), busy: busy, enabled: !busy && code.count == 6 && password.count >= 8,
                  id: "reset-submit") {
            Task { await reset() }
        }
        Text(words(.codeSpam)).font(.footnote).foregroundStyle(Theme.quiet)
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = secondsLeft(context.date)
            Button(left == 0 ? words(.resend) : words(.resendIn, String(left))) { Task { await send() } }
                .font(.callout.weight(.semibold))
                .disabled(left > 0 || busy)
        }
        Button(words(.changeDetails)) {
            verification = nil
            code = ""
            failure = nil
        }
        .font(.callout).foregroundStyle(Theme.quiet)
    }

    private func secondsLeft(_ now: Date) -> Int {
        guard let sentAt, let verification else { return 0 }
        let wait = Double(verification.resendAfter.components.seconds)
        return max(0, Int((wait - now.timeIntervalSince(sentAt)).rounded(.up)))
    }

    private func service() -> NyutagService { NyutagService(client: DoorHub.shared.makeClient()) }

    private func send() async {
        busy = true
        defer { busy = false }
        failure = nil
        guard await DoorHub.shared.waitUntilUp() else { failure = words(.noNetwork); return }
        do {
            verification = try await service().startPasswordReset(address: email.trimmingCharacters(in: .whitespaces))
            sentAt = .now
        } catch {
            failure = message(error)
        }
        #if DEBUG
        print("ui-check: сброс пароля, письмо \(verification == nil ? "не ушло: \(failure ?? "")" : "ушло")")
        #endif
    }

    private func reset() async {
        guard let verification else { return }
        busy = true
        failure = nil
        let userID: String
        do {
            userID = try await service().resetPassword(sid: verification.sid, token: code, password: password)
        } catch {
            failure = message(error)
            code = ""
            busy = false
            return
        }
        do throws(AppSession.SignInFailure) {
            try await session.signIn(identifier: userID, password: password)
        } catch {
            failure = words(error == .tooOften ? .tooOften : .noNetwork)
            busy = false
        }
    }

    private func message(_ error: MatrixError) -> String {
        if error.errcode == "NYUTAG_CONTACT_UNKNOWN" { return words(.resetUnknown) }
        return SignUpView.message(SignUpFlow.failure(error, contact: .email), words)
    }

    #if DEBUG
    /// SIMCTL_CHILD_NYUTAG_UI_RESET=адрес — запросить письмо. Код в чат не попадает, проверка заканчивается на письме.
    private func fillForScreenshots() async {
        guard let address = ProcessInfo.processInfo.environment["NYUTAG_UI_RESET"], verification == nil else { return }
        email = address
        await send()
    }
    #endif
}
