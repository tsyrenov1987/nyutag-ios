import NyutagCore
import SwiftUI

/// Корень: сначала язык (один раз), дальше вход или главный экран.
struct ContentView: View {
    @State private var words = Words()
    @State private var wallpapers = Wallpapers()
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
        .environment(wallpapers)
        .environment(session.calls)
        .environment(\.locale, (words.lang ?? .ru).locale)
        .tint(Theme.sky)
        .animation(.smooth, value: session.phase)
        .animation(.smooth, value: words.lang)
        .onOpenURL(perform: open)
        .task {
            await session.launch()
            #if DEBUG
            await signInForScreenshots()
            #endif
        }
    }

    private func open(_ url: URL) {
        // Ссылка-приглашение: без входа — сразу в регистрацию с кодом; вошедшему она не нужна.
        if let code = InviteCode.code(fromLink: url), session.phase != .signedIn { session.pendingInvite = code }
        // Виджет «Зурхай» открывает вкладку «Календарь».
        if url.scheme == "nyutag", url.host == "calendar" { session.requestedTab = 3 }
        // Ссылка на сообщество со страницы nyutag.chat/c/: вкладка «Сообщества», его карточка.
        if let spaceID = CommunityLink.roomID(from: url) {
            session.pendingCommunity = spaceID
            session.requestedTab = 2
        }
    }

    #if DEBUG
    /// Снимки экранов на симуляторе: вход из SIMCTL_CHILD_NYUTAG_UI_USER/PASSWORD без набора на клавиатуре.
    private func signInForScreenshots() async {
        let env = ProcessInfo.processInfo.environment
        if env["NYUTAG_UI_SIGNOUT"] != nil { return await session.signOut() }
        // NYUTAG_UI_URL=ссылка — как нажатие на виджет: simctl openurl спрашивает подтверждение, виджет — нет.
        if let link = env["NYUTAG_UI_URL"].flatMap(URL.init(string:)) {
            open(link)
            print("ui-check: ссылка \(link), вкладка \(session.requestedTab.map(String.init) ?? "без смены")")
        }
        defer {
            if let room = env["NYUTAG_UI_MAKE_ROOM"] { Task { await session.ensurePrivateRoom(named: room) } }
        }
        guard session.phase == .signedOut, let user = env["NYUTAG_UI_USER"], let password = env["NYUTAG_UI_PASSWORD"] else { return }
        // Гонка дверей идёт параллельно: первые попытки могут не дойти до ядра.
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
