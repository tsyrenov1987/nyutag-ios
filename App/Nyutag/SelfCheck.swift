// Нютаг. Самопроверка отладочной сборки на симуляторе или телефоне: весь путь приложения без интерфейса.
// Туннель поднимается → ядро отвечает через SOCKS (имя резолвит прокси) с пином CA → вход через хранитель
// (связка ключей и контейнер группы) → подъём сохранённого входа → /sync → выход со стиранием следов.
// Включается переменной окружения запуска SIMCTL_CHILD_NYUTAG_SELFCHECK=1; вход — только если заданы
// NYUTAG_SELFCHECK_USER/PASSWORD (без них проверяется путь до ядра). Пароль и токен не печатаются.

#if DEBUG
import Foundation
import NyutagCore

enum SelfCheck {
    static func runIfAsked() {
        let env = ProcessInfo.processInfo.environment
        guard env["NYUTAG_SELFCHECK"] != nil else { return }
        let credentials = env["NYUTAG_SELFCHECK_USER"].flatMap { user in env["NYUTAG_SELFCHECK_PASSWORD"].map { (user, $0) } }
        Task.detached { await run(credentials: credentials) }
    }

    private static func say(_ line: String) { print("selfcheck: \(line)") }

    private static func run(credentials: (user: String, password: String)?) async {
        let started = ContinuousClock.now
        let hub = TunnelHub.shared
        // Ждём первого открытого пути не дольше 30 с.
        var opened = false
        for _ in 0..<60 {
            switch await hub.state {
            case .up: opened = true
            case .failed(let failure): return say("туннель не поднялся: \(failure)")
            case .idle, .starting: break
            }
            if opened { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard opened else { return say("туннель не поднялся за 30 с") }
        say("туннель поднят за \(started.duration(to: .now))")

        let probe = hub.makeClient()
        // Путь приходит подпиской: даём ей долететь до клиента.
        try? await Task.sleep(for: .milliseconds(200))
        do {
            let versions: JSONValue = try await probe.raw(.get, "/_matrix/client/versions", authenticated: false)
            say("ядро ответило через туннель, версий \(versions["versions"]?.array?.count ?? 0)")
        } catch {
            return say("ядро не ответило: \(error)")
        }

        guard let (user, password) = credentials else { return say("готово (без входа) за \(started.duration(to: .now))") }
        guard let keeper = AccountKeeper.app() else { return say("нет права на группу приложений") }
        do {
            if let stale = try keeper.restore() { try keeper.forget(userID: stale.session.userID) }
            let account = try await keeper.signIn(homeserver: TunnelHub.coreURL, user: user, password: password,
                                                  deviceName: "Нютаг самопроверка (симулятор)")
            say("вход \(account.session.userID), устройство сохранено")
            guard let restored = try keeper.restore(), restored.session == account.session else {
                return say("сохранённый вход не поднялся")
            }
            try? await Task.sleep(for: .milliseconds(200))
            let engine = SyncEngine(client: restored.client, store: restored.store, session: restored.session)
            let first = try await engine.syncOnce()
            let rooms = try await restored.store.rooms()
            say("sync через туннель: начальный \(first.isInitial), комнат \(rooms.count)")
            try await keeper.signOut(restored)
            let left = try keeper.restore() == nil
            let wiped = !FileManager.default.fileExists(atPath: keeper.shelf.folder(for: account.session.userID)
                .path(percentEncoded: false))
            say("выход: связка пуста \(left), база стёрта \(wiped)")
            say("готово за \(started.duration(to: .now))")
        } catch {
            say("ошибка \(error)")
        }
    }
}
#endif
