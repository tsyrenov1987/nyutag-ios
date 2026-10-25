// Нютаг. Двери в процессе приложения: гонка проб по каталогу, выдача двери клиентам, повтор гонки при смене
// сети, возврате из фона и жалобе клиента. Пока двери нет, запросы клиентов ждут её (`MatrixClient.doorWait`)
// и падают ошибкой сети, если не дождались; на `core.nyutag.chat` напрямую они не ходят — снаружи он закрыт.

import Foundation
import NyutagCore

actor DoorHub {
    static let shared = DoorHub()

    /// Имя ядра для сессий и токенов; адрес запросов — дверь.
    static let coreURL = URL(string: "https://core.nyutag.chat")!

    enum State: Equatable {
        case idle
        case probing
        case up(Door)
        case failed
    }

    private(set) var state: State = .idle
    /// Каталог из бандла плюс двери, присланные сервером в прошлый раз.
    private var doors: [Door]
    private var watcher: Task<Void, Never>?
    private var race: Task<Void, Never>?
    private var lastRace: ContinuousClock.Instant?
    private var fetchedCatalogue = false
    private var subscribers: [UUID: AsyncStream<Door?>.Continuation] = [:]
    /// Дверь для новых клиентов, читается синхронно: до первой гонки — последняя удачная из памяти, чтобы
    /// сохранённый вход начал /sync сразу, а не после гонки.
    private nonisolated let current: Mutex<Door?>
    private let probes: URLSession

    private init() {
        #if DEBUG
        // Самопроверка «как в первый раз»: без памяти о прошлой двери.
        if ProcessInfo.processInfo.environment["NYUTAG_DOOR_FORGET"] != nil { DoorMemory.forget() }
        #endif
        let bundled = Self.bundled?.doors ?? []
        doors = DoorCatalogue.merge(bundled, DoorMemory.recallDynamic())
        current = Mutex(bundled.isEmpty ? nil : DoorMemory.recall()?.door)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 8
        configuration.urlCache = nil
        probes = URLSession(configuration: configuration)
    }

    /// Ключ и двери из бандла (`Catalogue/nyutag-catalogue.txt`, не в git). Содержимое нигде не печатается.
    private nonisolated static let bundled: DoorCatalogue? = {
        guard let url = Bundle.main.url(forResource: "nyutag-catalogue", withExtension: "txt", subdirectory: "Catalogue"),
              let text = try? String(contentsOf: url, encoding: .utf8),
              let catalogue = DoorCatalogue(text: text) else { return nil }
        #if DEBUG
        // Самопроверка по одной двери: оставляем двери с этим именем.
        if let only = ProcessInfo.processInfo.environment["NYUTAG_DOOR_ONLY"] {
            return DoorCatalogue(key: catalogue.key, doors: catalogue.doors.filter { $0.name == only })
        }
        #endif
        return catalogue
    }()

    // MARK: Запуск

    /// Один раз за процесс (повторные вызовы безвредны): первая гонка сразу, дальше по сети.
    func begin() {
        guard watcher == nil else { return }
        startRace()
        watcher = Task { [weak self] in
            for await _ in NetworkWatch.changes() {
                await self?.networkChanged()
            }
        }
    }

    /// Сеть сменилась (Wi-Fi → сотовая, другой Wi-Fi): лучшая дверь могла стать другой, а запертая — открыться.
    private func networkChanged() {
        guard let lastRace, lastRace.duration(to: .now) > .seconds(5) else { return }
        startRace()
    }

    private func startRace() {
        guard race == nil else { return }
        lastRace = .now
        Self.log("гонка: \(doors.count) дверей, знакомая \(current.withLock { $0 }?.name ?? "нет")")
        if case .up = state {} else { publish(.probing) }
        let doors = doors
        let preferred = current.withLock { $0 }
        let key = Self.bundled?.key
        let probes = probes
        race = Task { [weak self] in
            let winner = await DoorRace.run(doors, preferred: preferred, headStart: .milliseconds(400)) { door in
                await Self.knock(door, key: key, with: probes)
            }
            await self?.raceEnded(winner)
        }
    }

    private func raceEnded(_ winner: Door?) {
        race = nil
        Self.log(winner.map { "победила \($0.name)" } ?? "ни одна дверь не открылась")
        guard let winner else { return publish(.failed) }
        publish(.up(winner))
        if let key = Self.bundled?.key { DoorMemory.remember(winner, key: key) }
        if !fetchedCatalogue { fetchCatalogue(via: winner) }
    }

    /// Проба: ядро за дверью отвечает списком версий. Любой другой ответ — дверь не наша или заперта.
    private nonisolated static func knock(_ door: Door, key: String?, with session: URLSession) async -> Bool {
        var request = URLRequest(url: door.url.appending(path: "_matrix/client/versions"))
        if let key { request.setValue(key, forHTTPHeaderField: DoorCatalogue.headerName) }
        request.setValue("Nyutag", forHTTPHeaderField: "User-Agent")
        let started = ContinuousClock.now
        let answer: (Data, URLResponse)?
        do { answer = try await session.data(for: request) } catch {
            Self.log("дверь \(door.name): \(error.localizedDescription) за \(started.duration(to: .now))")
            return false
        }
        guard let (data, response) = answer, let http = response as? HTTPURLResponse else { return false }
        let open = http.statusCode == 200 && (try? JSONValue(data: data))?["versions"]?.array?.isEmpty == false
        Self.log("дверь \(door.name): \(http.statusCode)\(open ? "" : " (не ядро)") за \(started.duration(to: .now))")
        return open
    }

    /// Отладочный журнал гонки: имена дверей и время ответа, без ключа и адресов.
    private nonisolated static func log(_ line: String) {
        #if DEBUG
        print("doors: [\(String(format: "%.2f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)))] \(line)")
        #endif
    }

    /// Сервер может прислать новые двери (`doors` в каталоге): запоминаем их на следующие запуски.
    /// Раз за процесс, после первой удачной гонки.
    private func fetchCatalogue(via door: Door) {
        fetchedCatalogue = true
        let client = makeClient()
        Task { [weak self] in
            guard let json: JSONValue = try? await client.raw(.get, "/_nyutag/v1/catalogue", authenticated: false),
                  let lines = json["doors"]?.array?.compactMap(\.string) else { return }
            let fresh = DoorCatalogue.doors(from: lines)
            guard !fresh.isEmpty else { return }
            await self?.learned(fresh)
        }
    }

    private func learned(_ fresh: [Door]) {
        DoorMemory.rememberDynamic(fresh)
        doors = DoorCatalogue.merge(Self.bundled?.doors ?? [], fresh)
    }

    // MARK: Жалобы и возврат из фона

    /// Клиент не достучался до двери: если это наша текущая и гонка не шла только что — ищем заново.
    func trouble(_ door: Door) {
        guard current.withLock { $0 } == door, race == nil,
              lastRace.map({ $0.duration(to: .now) > .seconds(10) }) ?? true else { return }
        startRace()
    }

    /// Вызывать при переходе приложения в активное состояние: за время сна дверь могли запереть.
    func appBecameActive() async {
        switch state {
        case .up(let door):
            guard let lastRace, lastRace.duration(to: .now) > .seconds(30) else { return }
            if await !Self.knock(door, key: Self.bundled?.key, with: probes) { startRace() }
        case .failed, .idle:
            startRace()
        case .probing:
            break
        }
    }

    /// Ждёт открытой двери не дольше `limit`: вход сразу после запуска не должен упасть, пока идёт гонка.
    func waitUntilUp(within limit: Duration = .seconds(20)) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if case .up = state { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        if case .up = state { return true }
        return false
    }

    // MARK: Двери для клиентов

    /// Текущая дверь сразу, затем каждое изменение.
    func updates() -> AsyncStream<Door?> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Door?>.makeStream(bufferingPolicy: .bufferingNewest(1))
        subscribers[id] = continuation
        continuation.yield(current.withLock { $0 })
        continuation.onTermination = { [weak self] _ in
            Task { await self?.dropSubscriber(id) }
        }
        return stream
    }

    private func dropSubscriber(_ id: UUID) { subscribers[id] = nil }

    private func publish(_ new: State) {
        state = new
        let door: Door?
        switch new {
        case .up(let winner): door = winner
        case .failed: door = nil
        case .idle, .probing: return
        }
        let changed = current.withLock { old in
            defer { old = door }
            return old != door
        }
        guard changed else { return }
        for continuation in subscribers.values { continuation.yield(door) }
    }

    /// Клиент к ядру: стартует с текущей дверью (или ждёт её, пока идёт гонка), дальше следует за её сменами
    /// и жалуется сюда, если дверь не отвечает. Синхронный, чтобы годиться в фабрику `AccountKeeper`.
    nonisolated func makeClient(homeserver: URL = coreURL, accessToken: String? = nil) -> MatrixClient {
        let client = MatrixClient(homeserver: homeserver, accessToken: accessToken,
                                  doorKey: Self.bundled?.key, door: current.withLock { $0 })
        Task { [weak client] in
            await client?.setDoorTrouble { door in Task { await DoorHub.shared.trouble(door) } }
            let updates = await self.updates()
            client?.follow(updates)
        }
        return client
    }
}
