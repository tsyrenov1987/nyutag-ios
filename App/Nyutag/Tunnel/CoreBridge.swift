// Нютаг. Единственное место приложения, которое знает про C-интерфейс FarvaterCore.
// Всё остальное в слое туннеля работает с этим тонким мостом, а чистая логика (порты, ключи, прокси) — в NyutagCore.

import FarvaterCore
import Foundation

enum CoreBridge {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Логин и пароль SOCKS у ядра новые при каждом запуске.
    struct Credentials {
        let user: String
        let password: String
    }

    static var isRunning: Bool { MobileRunning() }

    /// Блокирует поток до готовности порта: вызывать только вне главного потока и вне исполнителя актора.
    static func start(catalogue: String, port: UInt16, network: String) throws {
        var error: NSError?
        guard MobileStart(catalogue, Int(port), network, &error) else {
            throw error ?? Failure(message: "ядро не запустилось")
        }
    }

    static func credentials() -> Credentials {
        Credentials(user: MobileSocksUser(), password: MobileSocksPass())
    }

    /// После сна iOS могла забрать слушающий сокет. Блокирует до двух секунд.
    static func ensureListening() -> Bool { MobileEnsureListening() }

    static func setNetwork(_ key: String) { MobileSetNetwork(key) }

    static func stop() { MobileStop() }

    /// Файл, где ядро хранит опыт о сетях между запусками. Вызывать до `start`.
    static func setMemoryFile(_ url: URL) { MobileSetMemoryFile(url.path(percentEncoded: false)) }
}
