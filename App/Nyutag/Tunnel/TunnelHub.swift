// Нютаг. Узел туннеля в процессе приложения: один запуск ядра на процесс, выдача пути клиентам,
// слежение за сетью и за слушающим портом. Пока туннель не поднят, клиенты получают закрытый путь
// (`Route.sealed`): запрос завершится ошибкой соединения, но не уйдёт напрямую.

import Foundation
import NyutagCore

actor TunnelHub {
    static let shared = TunnelHub()

    /// Ядро Нютага: имя резолвится на стороне прокси (SOCKS5 с доменным именем), локальный DNS не участвует.
    static let coreURL = URL(string: "https://core.nyutag.chat:6167")!

    private(set) var state: TunnelState = .idle
    private var networkKey: String?
    private var watcher: Task<Void, Never>?
    private var fallbackStart: Task<Void, Never>?
    private var subscribers: [UUID: AsyncStream<Route>.Continuation] = [:]
    private var lastPublished: Route?

    // MARK: Запуск

    /// Один раз за процесс (повторные вызовы безвредны): начинает слушать сеть и поднимает ядро, как только
    /// известен ключ сети. Если сеть молчит дольше 1,5 с, стартуем с нейтральным `wifi`.
    func begin() {
        guard watcher == nil else { return }
        publish(.starting)
        watcher = Task { [weak self] in
            for await key in NetworkWatch.keys() {
                await self?.networkChanged(key)
            }
        }
        fallbackStart = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            await self?.networkChanged(nil)
        }
    }

    private func networkChanged(_ key: String?) async {
        if let key { networkKey = key }
        switch state {
        case .up:
            if let key, CoreBridge.isRunning { CoreBridge.setNetwork(key) }
        case .idle, .failed, .starting:
            // Новая сеть — повод повторить неудавшийся запуск.
            await bringUp()
        }
    }

    private func bringUp() async {
        guard !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        fallbackStart?.cancel()
        publish(.starting)
        let network = networkKey ?? "wifi"
        let result: Result<SocksProxy, TunnelFailure> = await Task.detached(priority: .userInitiated) {
            Self.launchCore(network: network)
        }.value
        switch result {
        case .success(let proxy): publish(.up(proxy))
        case .failure(let failure): publish(.failed(failure))
        }
    }

    /// Защита от наложения двух запусков (смена сети во время старта).
    private var isStarting = false

    /// Блокирующая часть: каталог, перебор портов, чтение логина и пароля. Вне актора.
    private nonisolated static func launchCore(network: String) -> Result<SocksProxy, TunnelFailure> {
        guard let catalogue = loadCatalogue() else { return .failure(.noCatalogue) }
        if let memory = memoryFile() { CoreBridge.setMemoryFile(memory) }
        // Ядро могло остаться от прошлого запуска в этом же процессе (перезапуск после потери порта).
        if CoreBridge.isRunning { CoreBridge.stop() }
        do {
            let port = try TunnelPort.launch(nextPort: { UInt16.random(in: TunnelPort.range) },
                                             start: { try CoreBridge.start(catalogue: catalogue, port: $0, network: network) })
            let secret = CoreBridge.credentials()
            guard let proxy = TunnelEndpoint.proxy(port: Int(port), user: secret.user, password: secret.password) else {
                CoreBridge.stop()
                return .failure(.badEndpoint)
            }
            return .success(proxy)
        } catch let failure as TunnelFailure {
            return .failure(failure)
        } catch {
            // Текст ошибки ядра может назвать вход каталога; наружу отдаём только общий признак.
            return .failure(.startFailed("ядро не запустилось"))
        }
    }

    /// Секрет лежит в бандле (`nyutag-catalogue.txt`, не в git). Содержимое нигде не печатается.
    private nonisolated static func loadCatalogue() -> String? {
        guard let url = Bundle.main.url(forResource: "nyutag-catalogue", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private nonisolated static func memoryFile() -> URL? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true) else { return nil }
        let dir = base.appending(path: "Tunnel", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "memory.json")
    }

    // MARK: Возврат из фона

    /// Вызывать при переходе приложения в активное состояние, до того как клиенты начнут переподключаться.
    /// Если порт не вернулся, ядро перезапускается на новом порту, а клиенты получают новый путь.
    func appBecameActive() async {
        switch state {
        case .up:
            let alive = await Task.detached(priority: .userInitiated) {
                CoreBridge.isRunning && CoreBridge.ensureListening()
            }.value
            if !alive {
                // Пока перезапускаем, путь закрыт: старый порт всё равно мёртв.
                publish(.starting)
                await bringUp()
            }
        case .failed:
            await bringUp()
        case .idle, .starting:
            break
        }
    }

    // MARK: Пути для клиентов

    /// Текущий путь сразу, затем каждое изменение. Путь прямым не бывает.
    func routes() -> AsyncStream<Route> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Route>.makeStream(bufferingPolicy: .bufferingNewest(1))
        subscribers[id] = continuation
        continuation.yield(Route.forTunnel(state))
        continuation.onTermination = { [weak self] _ in
            Task { await self?.dropSubscriber(id) }
        }
        return stream
    }

    private func dropSubscriber(_ id: UUID) { subscribers[id] = nil }

    private func publish(_ new: TunnelState) {
        state = new
        let route = Route.forTunnel(new)
        guard route != lastPublished else { return }
        lastPublished = route
        for continuation in subscribers.values { continuation.yield(route) }
    }

    /// Клиент к ядру Нютага: стартует с закрытым путём, получает путь туннеля, как только он есть,
    /// и дальше следует за его изменениями. Пин своего CA включён. Синхронный, чтобы годиться в фабрику
    /// `AccountKeeper`; подписка на пути оформляется следом, первый путь приходит сразу при подписке.
    nonisolated func makeClient(homeserver: URL = coreURL, accessToken: String? = nil) -> MatrixClient {
        let client = MatrixClient(homeserver: homeserver, accessToken: accessToken,
                                  delegate: CertificateTrust.nyutagCore(), route: .sealed)
        Task { [weak client] in
            let updates = await self.routes()
            client?.follow(updates)
        }
        return client
    }
}
