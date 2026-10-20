// Нютаг. Путь запросов: напрямую или через локальный SOCKS5 туннеля.
// Туннель (FarvaterCore) живёт в приложении и при перезапуске может выйти на другом порту или с другим логином:
// движок получает новое описание пути и пересобирает сетевой сеанс (см. `MatrixClient.setRoute`).

import Foundation
import Network

/// SOCKS5-прокси с логином и паролем (у туннеля они одноразовые).
public struct SocksProxy: Sendable, Equatable, CustomStringConvertible {
    public let host: String
    public let port: UInt16
    public let user: String
    public let password: String

    /// `nil`, если порт 0 или адрес пуст: такой прокси не может работать.
    public init?(host: String = "127.0.0.1", port: UInt16, user: String, password: String) {
        guard port != 0, !host.isEmpty else { return nil }
        self.host = host
        self.port = port
        self.user = user
        self.password = password
    }

    /// Пароль в логи не попадает.
    public var description: String { "socks5://\(user):***@\(host):\(port)" }
}

public enum Route: Sendable, Equatable {
    /// Без прокси: тесты на Маке и сборки без туннеля.
    case direct
    case socks5(SocksProxy)

    /// Конфигурация сеанса с этим путём поверх `base`. База не меняется, возвращается копия.
    /// `proxyConfigurations` и `ProxyConfiguration(socksv5Proxy:)` — iOS 17+/macOS 14+, платформы пакета выше.
    public func apply(to base: URLSessionConfiguration) -> URLSessionConfiguration {
        guard let configuration = base.copy() as? URLSessionConfiguration else { return base }
        switch self {
        case .direct:
            configuration.proxyConfigurations = []
        case .socks5(let proxy):
            // Порт уже проверен в SocksProxy.init, поэтому `.any` здесь недостижим.
            let port = NWEndpoint.Port(rawValue: proxy.port) ?? .any
            var socks = ProxyConfiguration(socksv5Proxy: .hostPort(host: NWEndpoint.Host(proxy.host), port: port))
            socks.applyCredential(username: proxy.user, password: proxy.password)
            // Без отката на прямое соединение: при мёртвом туннеле запрос должен упасть, а не уйти в обход него
            // с настоящим адресом пользователя.
            socks.allowFailover = false
            configuration.proxyConfigurations = [socks]
        }
        return configuration
    }
}

extension MatrixClient {
    /// Клиент переключается на каждый путь из потока (туннель перезапустился на другом порту), пока сам жив.
    /// Поток не удерживает клиента: после выхода из учётки клиент освобождается, и подписка кончается
    /// на следующем пути.
    @discardableResult
    public nonisolated func follow(_ routes: AsyncStream<Route>) -> Task<Void, Never> {
        Task { [weak self] in
            for await route in routes {
                guard let self else { return }
                await self.setRoute(route)
            }
        }
    }
}
