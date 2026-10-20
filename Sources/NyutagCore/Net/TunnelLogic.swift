// Нютаг. Чистая логика туннеля без зависимости от FarvaterCore: ключ сети, выбор и повтор порта,
// сборка SOCKS-прокси и решение «какой путь отдать клиенту». Сам туннель живёт в App/Nyutag/Tunnel,
// здесь только то, что можно проверить тестами на Маке.

import CryptoKit
import Foundation

// MARK: Ключ сети

/// Вид сети, как его различает ядро: от ключа зависит, под какой записью оно хранит опыт о путях.
public enum LinkKind: Sendable, Equatable {
    case wifi
    case cellular
    case wired
    /// Туннельные и прочие интерфейсы: ядру отдаём нейтральный ключ.
    case other
}

public enum NetworkKey {
    /// Ключ для `MobileStart` / `MobileSetNetwork`: `wifi`, `wifi:<отпечаток шлюзов>`, `cell`, `wired`.
    /// Отпечаток не зависит от порядка и повторов адресов шлюзов и не раскрывает сами адреса.
    /// Wi-Fi без известных шлюзов даёт просто `wifi`.
    public static func make(kind: LinkKind, gateways: [String]) -> String {
        switch kind {
        case .cellular: return "cell"
        case .wired: return "wired"
        case .other: return "other"
        case .wifi:
            let unique = Set(gateways.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
            guard !unique.isEmpty else { return "wifi" }
            let joined = unique.sorted().joined(separator: "|")
            let digest = SHA256.hash(data: Data(("nyutag-gw:" + joined).utf8))
            return "wifi:" + digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        }
    }
}

// MARK: Порт

public enum TunnelPort {
    /// Диапазон динамических портов: чужие приложения на loopback там же, поэтому занятость — штатный случай.
    public static let range: ClosedRange<UInt16> = 49_152...65_000

    /// Ядро отвечает текстом ошибки (Go: `bind: address already in use`) или POSIX-кодом EADDRINUSE.
    public static func isAddressInUse(_ error: any Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EADDRINUSE) { return true }
        let text = (ns.localizedDescription + " " + String(describing: error)).lowercased()
        return text.contains("address already in use")
    }

    /// Запускает туннель на порту из `nextPort`; если порт занят, берёт следующий, но не больше `attempts` раз.
    /// Любая другая ошибка (каталог, сеть) отдаётся сразу: перебор портов её не лечит.
    public static func launch(attempts: Int = 8,
                              nextPort: () -> UInt16,
                              start: (UInt16) throws -> Void) throws -> UInt16 {
        var last: (any Error)?
        for _ in 0..<max(attempts, 1) {
            let port = nextPort()
            do {
                try start(port)
                return port
            } catch {
                guard isAddressInUse(error) else { throw error }
                last = error
            }
        }
        throw last ?? TunnelFailure.noFreePort
    }
}

// MARK: Прокси и состояние

public enum TunnelFailure: Error, Sendable, Equatable {
    case noCatalogue
    case noFreePort
    case startFailed(String)
    case badEndpoint
    /// Порт не вернулся после сна, а перезапуск не удался.
    case lost
}

public enum TunnelEndpoint {
    /// Прокси ядра на loopback. Без логина и пароля прокси не принимаем: порт открыт для всех приложений
    /// устройства, и безымянный вход значил бы, что мы говорим не со своим ядром.
    public static func proxy(port: Int, user: String, password: String) -> SocksProxy? {
        guard (1...Int(UInt16.max)).contains(port), !user.isEmpty, !password.isEmpty else { return nil }
        return SocksProxy(host: "127.0.0.1", port: UInt16(port), user: user, password: password)
    }
}

public enum TunnelState: Sendable, Equatable {
    case idle
    case starting
    case up(SocksProxy)
    case failed(TunnelFailure)
}

extension Route {
    /// «Закрытый» путь: SOCKS5 на loopback-порт, где никто не слушает. Запрос упадёт ошибкой соединения,
    /// а не уйдёт напрямую с настоящим адресом (откат на прямое у такого пути выключен в `Route.apply`).
    public static let sealed: Route = {
        guard let dead = SocksProxy(port: 1, user: "closed", password: "closed") else { return .direct }
        return .socks5(dead)
    }()

    /// Путь для клиента в данном состоянии туннеля. Прямым он не бывает никогда.
    public static func forTunnel(_ state: TunnelState) -> Route {
        if case .up(let proxy) = state { return .socks5(proxy) }
        return .sealed
    }
}
