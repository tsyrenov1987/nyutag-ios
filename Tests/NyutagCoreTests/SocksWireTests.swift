// Транспорт: что URLSession кладёт в CONNECT прокси туннеля. Публичный DNS отдаёт под core.nyutag.chat чужой адрес,
// настоящий знают только выходы туннеля, поэтому имя должно уходить в прокси как имя (ATYP 3), а не как IP.
// Прокси здесь — крошечный SOCKS5 на loopback: принимает логин, записывает адрес из CONNECT и отказывает.

import Foundation
import Testing
@testable import NyutagCore

/// Однократный SOCKS5 на блокирующих сокетах: один клиент, один CONNECT.
private final class SocksRecorder: @unchecked Sendable {
    struct Request: Equatable {
        let addressType: UInt8
        let host: String
        let port: UInt16
    }

    let port: UInt16
    private let listener: Int32
    private let lock = NSLock()
    private var captured: Request?
    private let done = DispatchSemaphore(value: 0)

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
        }
        guard bound == 0, listen(fd, 4) == 0 else { close(fd); throw POSIXError(.EADDRINUSE) }
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        listener = fd
        port = UInt16(bigEndian: address.sin_port)
        Thread.detachNewThread { [self] in serve() }
    }

    /// Адрес из CONNECT; `nil`, если клиент так и не дошёл до CONNECT.
    func request(timeout: TimeInterval) -> Request? {
        _ = done.wait(timeout: .now() + timeout)
        return lock.withLock { captured }
    }

    private func serve() {
        defer { close(listener); done.signal() }
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }
        // Приветствие: версия, число методов, методы. Выбираем логин и пароль (0x02).
        guard let hello = read(client, 2), hello[0] == 5, read(client, Int(hello[1])) != nil,
              write(client, [5, 2]) else { return }
        // Логин и пароль (RFC 1929): принимаем любые.
        guard let auth = read(client, 2), let user = read(client, Int(auth[1])), user.count == Int(auth[1]),
              let passLength = read(client, 1), read(client, Int(passLength[0])) != nil, write(client, [1, 0]) else { return }
        // CONNECT: VER CMD RSV ATYP адрес порт.
        guard let head = read(client, 4), head[1] == 1 else { return }
        let host: String
        switch head[3] {
        case 1:
            guard let ip = read(client, 4) else { return }
            host = ip.map(String.init).joined(separator: ".")
        case 3:
            guard let size = read(client, 1), let name = read(client, Int(size[0])) else { return }
            host = String(decoding: name, as: UTF8.self)
        case 4:
            guard let ip = read(client, 16) else { return }
            host = ip.map { String(format: "%02x", $0) }.joined()
        default:
            return
        }
        guard let portBytes = read(client, 2) else { return }
        lock.withLock {
            captured = Request(addressType: head[3], host: host, port: UInt16(portBytes[0]) << 8 | UInt16(portBytes[1]))
        }
        // Отказ «узел недоступен»: дальше клиенту идти некуда.
        _ = write(client, [5, 4, 0, 1, 0, 0, 0, 0, 0, 0])
    }

    private func read(_ fd: Int32, _ count: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress! + got, count - got, 0) }
            guard n > 0 else { return nil }
            got += n
        }
        return buffer
    }

    private func write(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBytes { send(fd, $0.baseAddress, bytes.count, 0) } == bytes.count
    }
}

@Suite("Транспорт: имя уходит в прокси")
struct SocksWireTests {
    @Test("CONNECT несёт имя ядра (ATYP 3) и порт, локальный DNS не участвует")
    func hostnameGoesToProxy() async throws {
        let recorder = try SocksRecorder()
        let proxy = try #require(SocksProxy(port: recorder.port, user: "u", password: "p"))
        let client = MatrixClient(homeserver: URL(string: "https://core.nyutag.chat:6167")!,
                                  delegate: CertificateTrust.nyutagCore(), route: .socks5(proxy))
        // После отказа прокси URLSession ждёт до своего таймаута: ответ не нужен, запрос снимаем.
        let call = Task { let _: JSONValue = try await client.raw(.get, "/_matrix/client/versions", authenticated: false) }
        let request = try #require(recorder.request(timeout: 5), "прокси не получил CONNECT")
        call.cancel()
        print("socks wire: ATYP \(request.addressType), адрес \(request.host):\(request.port)")
        #expect(request == .init(addressType: 3, host: "core.nyutag.chat", port: 6167))
    }

    @Test("запрос, начатый до туннеля, снимается при смене пути, а не ждёт связи до таймаута")
    func sealedRequestEndsOnRouteChange() async throws {
        let client = MatrixClient(homeserver: URL(string: "https://core.nyutag.chat:6167")!,
                                  delegate: CertificateTrust.nyutagCore(), route: .sealed)
        let started = ContinuousClock.now
        let call = Task { () -> Bool in
            do { let _: JSONValue = try await client.raw(.get, "/_matrix/client/versions", authenticated: false) } catch {
                return true
            }
            return false
        }
        try await Task.sleep(for: .milliseconds(500))
        let other = try #require(SocksProxy(port: 2, user: "u", password: "p"))
        await client.setRoute(.socks5(other))
        let failed = await call.value
        let waited = started.duration(to: .now)
        print("закрытый путь: запрос завершился за \(waited)")
        #expect(failed)
        #expect(waited < .seconds(10))
    }
}
