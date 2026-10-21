// Нютаг. Регистрация в два шага: форма (имя, телефон, почта, пароль) и код из письма.
// Адрес в Нютаге подставляется из имени сам; поменять его можно касанием.

import SwiftUI
import NyutagCore

struct SignUpView: View {
    @Environment(Words.self) private var words
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var flow = SignUpFlow()
    @State private var name = ""
    @State private var phone = ""
    @State private var email = ""
    @State private var password = ""
    @State private var invite: String
    @State private var editingNick = false
    @State private var nickText = ""
    @State private var busy = false
    @State private var failure: SignUpFlow.Failure?
    @State private var codeShown = false
    @FocusState private var field: Field?

    enum Field { case name, nick, phone, email, password, invite }

    init(invite: String = "") {
        _invite = State(initialValue: invite)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(words(.signUpLead)).foregroundStyle(Theme.quiet)
                    form
                    if let failure { FailureNote(text: message(failure)) }
                    BigButton(title: busy ? words(.sendingCode) : words(.getCode), busy: busy, enabled: canSubmit,
                              id: "signup-submit", action: submit)
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.milk.ignoresSafeArea())
            .navigationTitle(words(.signUpTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(words(.cancel)) { dismiss() } }
            }
            .navigationDestination(isPresented: $codeShown) {
                SignUpCodeView(flow: flow, email: email, name: name, password: password, invite: invite)
            }
            .task { await flow.prepare() }
            .onAppear { field = .name }
            #if DEBUG
            .task { await fillForScreenshots() }
            #endif
        }
    }

    private var form: some View {
        VStack(spacing: 0) {
            TextField(words(.name), text: $name)
                .textContentType(.name)
                .submitLabel(.next)
                .focused($field, equals: .name)
                .onSubmit { field = .phone }
                .onChange(of: name) { flow.nameChanged(name) }
                .padding(16)
                .accessibilityIdentifier("signup-name")
            nickRow
            Divider().padding(.leading, 16)
            TextField(words(.phone), text: $phone)
                .textContentType(.telephoneNumber)
                .keyboardType(.phonePad)
                .focused($field, equals: .phone)
                .padding(16)
                .accessibilityIdentifier("signup-phone")
            Divider().padding(.leading, 16)
            TextField(words(.email), text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .focused($field, equals: .email)
                .onSubmit { field = .password }
                .padding(16)
                .accessibilityIdentifier("signup-email")
            Divider().padding(.leading, 16)
            SecureField(words(.newPassword), text: $password)
                .textContentType(.newPassword)
                .submitLabel(flow.needsInvite ? .next : .go)
                .focused($field, equals: .password)
                .onSubmit { if flow.needsInvite { field = .invite } else { submit() } }
                .padding(16)
                .accessibilityIdentifier("signup-password")
            if flow.needsInvite || !invite.isEmpty {
                Divider().padding(.leading, 16)
                TextField(words(.inviteCode), text: $invite)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                    .submitLabel(.go)
                    .focused($field, equals: .invite)
                    .onSubmit(submit)
                    .padding(16)
                    .accessibilityIdentifier("signup-invite")
            }
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// Адрес под именем: подставляется сам, по касанию правится.
    @ViewBuilder private var nickRow: some View {
        if editingNick {
            HStack(spacing: 4) {
                Text("@").foregroundStyle(Theme.quiet)
                TextField(words(.nickLabel), text: $nickText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($field, equals: .nick)
                    .onChange(of: nickText) { flow.nickEdited(nickText) }
                nickMark
            }
            .font(.callout)
            .padding(.horizontal, 16).padding(.bottom, 12)
        } else if !flow.nick.isEmpty {
            Button {
                nickText = flow.nick
                editingNick = true
                field = .nick
            } label: {
                HStack(spacing: 6) {
                    Text(words(.nickLabel) + ":").foregroundStyle(Theme.quiet)
                    Text("@" + flow.nick).foregroundStyle(Theme.ink).lineLimit(1)
                    nickMark
                    Spacer(minLength: 0)
                    Image(systemName: "pencil").foregroundStyle(Theme.quiet)
                }
                .font(.footnote)
                .padding(.horizontal, 16).padding(.bottom, 12)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("signup-nick")
        }
        if flow.nickState == .taken || flow.nickState == .invalid {
            Text(words(flow.nickState == .taken ? .nickTaken : .nickRules))
                .font(.footnote).foregroundStyle(Theme.gold)
                .padding(.horizontal, 16).padding(.bottom, 12)
        }
    }

    @ViewBuilder private var nickMark: some View {
        switch flow.nickState {
        case .checking: ProgressView().controlSize(.mini)
        case .free: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.read)
        case .taken, .invalid: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.gold)
        case .empty: EmptyView()
        }
    }

    private var canSubmit: Bool {
        guard !busy, flow.configuration != nil, flow.nickState == .free,
              !name.trimmingCharacters(in: .whitespaces).isEmpty,
              email.contains("@"), password.count >= 8 else { return false }
        if flow.configuration?.requiresPhone == true, phone.filter(\.isNumber).count < 7 { return false }
        if flow.needsInvite, invite.filter({ !$0.isWhitespace }).count < 6 { return false }
        return true
    }

    private func submit() {
        guard canSubmit else { return }
        busy = true
        failure = nil
        Task {
            do throws(SignUpFlow.Failure) {
                try await flow.sendCode(phone: phone, email: email, invite: invite)
                codeShown = true
            } catch {
                failure = error
                #if DEBUG
                print("ui-check: регистрация, отказ формы: \(error)")
                #endif
            }
            busy = false
        }
    }

    private func message(_ failure: SignUpFlow.Failure) -> String { SignUpView.message(failure, words) }

    static func message(_ failure: SignUpFlow.Failure, _ words: Words) -> String {
        switch failure {
        case .phoneTaken: words(.phoneTaken)
        case .emailTaken: words(.emailTaken)
        case .badPhone: words(.badPhone)
        case .badEmail: words(.badEmail)
        case .nickTaken: words(.nickTaken)
        case .badNick: words(.nickRules)
        case .weakPassword: words(.weakPassword)
        case .badInvite: words(.badInvite)
        case .inviteUsed: words(.inviteUsed)
        case .wrongCode: words(.wrongCode)
        case .codeExpired: words(.codeExpired)
        case .tooManyTries: words(.tooManyTries)
        case .tooOften: words(.tooOften)
        case .mailFailed: words(.mailFailed)
        case .noNetwork, .broken: words(.noNetwork)
        }
    }

    #if DEBUG
    /// Самопроверка на телефоне: NYUTAG_UI_SIGNUP = JSON {name, phone, email, password}; код потом кладётся файлом.
    private func fillForScreenshots() async {
        guard let raw = ProcessInfo.processInfo.environment["NYUTAG_UI_SIGNUP"],
              let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: String] else { return }
        name = json["name"] ?? ""
        phone = json["phone"] ?? ""
        email = json["email"] ?? ""
        password = json["password"] ?? ""
        for _ in 0..<60 where !canSubmit { try? await Task.sleep(for: .milliseconds(500)) }
        print("ui-check: регистрация, ник @\(flow.nick) \(flow.nickState)")
        submit()
    }
    #endif
}

struct SignUpCodeView: View {
    @Environment(Words.self) private var words
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let flow: SignUpFlow
    let email: String
    let name: String
    let password: String
    let invite: String
    @State private var code = ""
    @State private var busy = false
    @State private var failure: SignUpFlow.Failure?
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(words(.codeSent, email.trimmingCharacters(in: .whitespaces))).foregroundStyle(Theme.ink)
                TextField("000000", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.system(size: 34, weight: .semibold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .focused($focused)
                    .onChange(of: code) {
                        let digits = String(code.filter(\.isNumber).prefix(6))
                        if digits != code { code = digits }
                        if digits.count == 6 { check() }
                    }
                    .padding(.vertical, 18)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .accessibilityIdentifier("signup-code")
                if busy {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(words(.creatingAccount)).foregroundStyle(Theme.quiet)
                    }
                }
                if let failure { FailureNote(text: SignUpView.message(failure, words)) }
                Text(words(.codeSpam)).font(.footnote).foregroundStyle(Theme.quiet)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let ready = flow.canResend(at: context.date)
                    Button(ready ? words(.resend) : words(.resendIn, String(secondsLeft(context.date)))) { resend() }
                        .font(.callout.weight(.semibold))
                        .disabled(!ready || busy)
                }
                Button(words(.changeDetails)) {
                    flow.forgetCode()
                    dismiss()
                }
                .font(.callout).foregroundStyle(Theme.quiet)
            }
            .padding(20)
        }
        .background(Theme.milk.ignoresSafeArea())
        .navigationTitle(words(.codeTitle))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { focused = true }
        #if DEBUG
        .task { await codeForScreenshots() }
        #endif
    }

    private func secondsLeft(_ now: Date) -> Int {
        guard let sentAt = flow.sentAt, let verification = flow.verification else { return 0 }
        let wait = Double(verification.resendAfter.components.seconds)
        return max(0, Int((wait - now.timeIntervalSince(sentAt)).rounded(.up)))
    }

    private func check() {
        guard !busy else { return }
        busy = true
        failure = nil
        Task {
            do throws(SignUpFlow.Failure) {
                try await flow.finish(token: code, name: name, password: password, invite: invite, session: session)
                #if DEBUG
                print("ui-check: регистрация выполнена")
                #endif
            } catch {
                failure = error
                code = ""
                busy = false
                #if DEBUG
                print("ui-check: регистрация, отказ кода: \(error)")
                #endif
            }
        }
    }

    private func resend() {
        Task {
            do throws(SignUpFlow.Failure) {
                // Номер уже проверен; повторное письмо — новая сессия подтверждения.
                try await flow.sendCode(phone: flow.phone ?? "", email: email, invite: invite)
                failure = nil
            } catch {
                failure = error
            }
        }
    }

    #if DEBUG
    /// Код с Мака: файл Documents/ui-code.txt (devicectl copy to), ждём до трёх минут.
    private func codeForScreenshots() async {
        guard ProcessInfo.processInfo.environment["NYUTAG_UI_SIGNUP"] != nil,
              let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let file = docs.appendingPathComponent("ui-code.txt")
        try? FileManager.default.removeItem(at: file)
        print("ui-check: регистрация, жду код")
        for _ in 0..<180 {
            if let text = try? String(contentsOf: file, encoding: .utf8), text.filter(\.isNumber).count == 6 {
                code = text.filter(\.isNumber)
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }
    #endif
}

/// Золотая плашка с ошибкой, общая для форм входа и регистрации.
struct FailureNote: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.bubble")
            .font(.callout).foregroundStyle(Theme.ink)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.gold.opacity(0.18), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Главная кнопка формы: голубая, с крутилкой, бледная, пока нажимать рано.
struct BigButton: View {
    let title: String
    let busy: Bool
    let enabled: Bool
    let id: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if busy { ProgressView().tint(.white) }
                Text(title).font(.headline)
            }
            .frame(maxWidth: .infinity, minHeight: 54)
            .foregroundStyle(.white)
            .background(Theme.sky.opacity(enabled ? 1 : 0.45), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityIdentifier(id)
    }
}
