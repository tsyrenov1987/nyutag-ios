// Нютаг. Первый запуск: язык одним касанием, дальше одна форма входа. Регистрация по приглашению — отдельным
// экраном следующим шагом; здесь только ссылка на неё.

import SwiftUI

struct LanguageView: View {
    @Environment(Words.self) private var words

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .font(.system(size: 56))
                .foregroundStyle(Theme.sky, Theme.gold)
            VStack(spacing: 6) {
                Text("Нютаг").font(.system(.largeTitle, design: .rounded, weight: .bold)).foregroundStyle(Theme.ink)
                Text("Хэлэн шэлэгты · Выберите язык · Choose a language")
                    .font(.footnote).foregroundStyle(Theme.quiet).multilineTextAlignment(.center)
            }
            VStack(spacing: 12) {
                ForEach(Lang.allCases) { lang in
                    Button { words.choose(lang) } label: {
                        Text(lang.ownName)
                            .font(.title3.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .foregroundStyle(lang == .bxr ? Theme.onGold : Theme.ink)
                            .background(lang == .bxr ? AnyShapeStyle(Theme.gold) : AnyShapeStyle(Theme.card),
                                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("lang-\(lang.rawValue)")
                }
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.milk.ignoresSafeArea())
    }
}

struct SignInView: View {
    @Environment(Words.self) private var words
    @Environment(AppSession.self) private var session
    @State private var identifier = ""
    @State private var password = ""
    @State private var busy = false
    @State private var failure: AppSession.SignInFailure?
    @FocusState private var field: Field?

    enum Field { case identifier, password }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(words(.welcome))
                        .font(.system(.largeTitle, design: .rounded, weight: .bold)).foregroundStyle(Theme.ink)
                    Text(words(.signInLead)).foregroundStyle(Theme.quiet)
                }
                .padding(.top, 48)

                VStack(spacing: 0) {
                    TextField(words(.identifier), text: $identifier)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($field, equals: .identifier)
                        .onSubmit { field = .password }
                        .padding(16)
                        .accessibilityIdentifier("signin-identifier")
                    Divider().padding(.leading, 16)
                    SecureField(words(.password), text: $password)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .focused($field, equals: .password)
                        .onSubmit(submit)
                        .padding(16)
                        .accessibilityIdentifier("signin-password")
                }
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                if let failure {
                    Label(message(failure), systemImage: "exclamationmark.bubble")
                        .font(.callout).foregroundStyle(Theme.ink)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.gold.opacity(0.18), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                Button(action: submit) {
                    HStack(spacing: 10) {
                        if busy { ProgressView().tint(.white) }
                        Text(busy ? words(.signingIn) : words(.signIn)).font(.headline)
                    }
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .foregroundStyle(.white)
                    .background(Theme.sky.opacity(canSubmit ? 1 : 0.45), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
                .accessibilityIdentifier("signin-submit")

                Text(words(.noAccount)).font(.footnote).foregroundStyle(Theme.quiet)
            }
            .padding(.horizontal, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.milk.ignoresSafeArea())
        .onAppear { field = .identifier }
    }

    private var canSubmit: Bool {
        !busy && !identifier.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
    }

    private func submit() {
        guard canSubmit else { return }
        busy = true
        failure = nil
        Task {
            do throws(AppSession.SignInFailure) {
                try await session.signIn(identifier: identifier, password: password)
            } catch {
                failure = error
                busy = false
            }
        }
    }

    private func message(_ failure: AppSession.SignInFailure) -> String {
        switch failure {
        case .wrongPassword: words(.wrongPassword)
        case .tooOften: words(.tooOften)
        case .noNetwork, .broken: words(.noNetwork)
        }
    }
}
