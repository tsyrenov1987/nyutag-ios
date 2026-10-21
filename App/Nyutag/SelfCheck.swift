// Нютаг. Самопроверка отладочной сборки на симуляторе или телефоне: весь путь приложения без интерфейса.
// Гонка дверей → ядро отвечает через дверь → вход через хранитель (связка ключей и контейнер группы) →
// подъём сохранённого входа → /sync → выход со стиранием следов.
// Включается переменной окружения запуска SIMCTL_CHILD_NYUTAG_SELFCHECK=1; вход — только если заданы
// NYUTAG_SELFCHECK_USER/PASSWORD (без них проверяется путь до ядра). Пароль, токен и ключ двери не печатаются.

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

    private static func say(_ line: String) {
        print("selfcheck: [\(String(format: "%.2f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)))] \(line)")
    }

    private static func run(credentials: (user: String, password: String)?) async {
        let started = ContinuousClock.now
        say("старт")
        let hub = DoorHub.shared
        guard await hub.waitUntilUp(within: .seconds(30)) else { return say("дверь не нашлась за 30 с: \(await hub.state)") }
        guard case .up(let door) = await hub.state else { return say("дверь пропала") }
        say("дверь \(door.name) за \(started.duration(to: .now))")

        let probe = hub.makeClient()
        do {
            let versions: JSONValue = try await probe.raw(.get, "/_matrix/client/versions", authenticated: false)
            say("ядро ответило через дверь, версий \(versions["versions"]?.array?.count ?? 0)")
        } catch {
            return say("ядро не ответило: \(error)")
        }

        guard let (user, password) = credentials else { return say("готово (без входа) за \(started.duration(to: .now))") }
        guard let keeper = AccountKeeper.app() else { return say("нет права на группу приложений") }
        do {
            if let stale = try keeper.restore() { try keeper.forget(userID: stale.session.userID) }
            let account = try await keeper.signIn(homeserver: DoorHub.coreURL, user: user, password: password,
                                                  deviceName: "Нютаг самопроверка (симулятор)")
            say("вход \(account.session.userID), устройство сохранено")
            guard let restored = try keeper.restore(), restored.session == account.session else {
                return say("сохранённый вход не поднялся")
            }
            let engine = SyncEngine(client: restored.client, store: restored.store, session: restored.session)
            let first = try await engine.syncOnce()
            let rooms = try await restored.store.rooms()
            say("sync через дверь: начальный \(first.isInitial), комнат \(rooms.count)")
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
