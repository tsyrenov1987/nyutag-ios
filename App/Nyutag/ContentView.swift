import NyutagCore
import SwiftUI

/// Корень: сначала язык (один раз), дальше вход или главный экран.
struct ContentView: View {
    @State private var words = Words()
    @State private var session = AppSession.shared

    var body: some View {
        ZStack {
            if words.lang == nil {
                LanguageView()
            } else {
                switch session.phase {
                case .launching: Theme.milk.ignoresSafeArea()
                case .signedOut: SignInView()
                case .signedIn: HomeView()
                }
            }
        }
        .environment(words)
        .environment(session)
        .environment(session.calls)
        .environment(\.locale, (words.lang ?? .ru).locale)
        .tint(Theme.sky)
        .animation(.smooth, value: session.phase)
        .animation(.smooth, value: words.lang)
        .onOpenURL { url in
            // Ссылка-приглашение: без входа — сразу в регистрацию с кодом; вошедшему она не нужна.
            if let code = InviteCode.code(fromLink: url), session.phase != .signedIn { session.pendingInvite = code }
        }
        .task {
            await session.launch()
            #if DEBUG
            await signInForScreenshots()
            #endif
        }
    }

    #if DEBUG
    /// Снимки экранов на симуляторе: вход из SIMCTL_CHILD_NYUTAG_UI_USER/PASSWORD без набора на клавиатуре.
    private func signInForScreenshots() async {
        let env = ProcessInfo.processInfo.environment
        if env["NYUTAG_UI_SIGNOUT"] != nil { return await session.signOut() }
        defer {
            if let room = env["NYUTAG_UI_MAKE_ROOM"] { Task { await session.ensurePrivateRoom(named: room) } }
        }
        guard session.phase == .signedOut, let user = env["NYUTAG_UI_USER"], let password = env["NYUTAG_UI_PASSWORD"] else { return }
        // Туннель поднимается параллельно: первые попытки могут не дойти до ядра.
        for attempt in 1...6 {
            do throws(AppSession.SignInFailure) {
                try await session.signIn(identifier: user, password: password)
                return print("ui-check: вход выполнен")
            } catch {
                print("ui-check: вход, попытка \(attempt): \(error)")
                if error != .noNetwork { return }
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }
    #endif
}
