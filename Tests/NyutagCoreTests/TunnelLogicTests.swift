// Логика туннеля: ключ сети, повтор порта, сборка прокси, отказ вместо утечки.

import Foundation
import Testing
@testable import NyutagCore

@Suite("Туннель: чистая логика")
struct TunnelLogicTests {
    // MARK: ключ сети

    @Test("Мобильная и проводная сети не зависят от шлюзов")
    func fixedKeys() {
        #expect(NetworkKey.make(kind: .cellular, gateways: ["10.0.0.1"]) == "cell")
        #expect(NetworkKey.make(kind: .wired, gateways: ["10.0.0.1"]) == "wired")
    }

    @Test("Wi-Fi без шлюзов — просто wifi")
    func wifiWithoutGateways() {
        #expect(NetworkKey.make(kind: .wifi, gateways: []) == "wifi")
        #expect(NetworkKey.make(kind: .wifi, gateways: ["  ", ""]) == "wifi")
    }

    @Test("Отпечаток шлюзов не зависит от порядка и повторов, но различает сети")
    func wifiFingerprint() {
        let a = NetworkKey.make(kind: .wifi, gateways: ["192.168.1.1", "fe80::1"])
        let b = NetworkKey.make(kind: .wifi, gateways: ["FE80::1", "192.168.1.1", "192.168.1.1"])
        let other = NetworkKey.make(kind: .wifi, gateways: ["192.168.0.1"])
        #expect(a == b)
        #expect(a != other)
        #expect(a.hasPrefix("wifi:"))
        #expect(a.count == "wifi:".count + 12)
        #expect(!a.contains("192"))
    }

    // MARK: порт

    private struct Busy: Error, LocalizedError {
        var errorDescription: String? { "listen tcp 127.0.0.1:50000: bind: address already in use" }
    }

    @Test("Занятый порт: берём следующий и возвращаем тот, что взялся")
    func retryOnBusy() throws {
        var ports: [UInt16] = [50_000, 50_001, 50_002]
        var tried: [UInt16] = []
        let got = try TunnelPort.launch(nextPort: { ports.removeFirst() }, start: { port in
            tried.append(port)
            if port != 50_002 { throw Busy() }
        })
        #expect(got == 50_002)
        #expect(tried == [50_000, 50_001, 50_002])
    }

    @Test("POSIX EADDRINUSE тоже считается занятым портом")
    func posixBusy() {
        #expect(TunnelPort.isAddressInUse(NSError(domain: NSPOSIXErrorDomain, code: Int(EADDRINUSE))))
        #expect(!TunnelPort.isAddressInUse(NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED))))
    }

    @Test("Другая ошибка не лечится перебором: падаем с первой попытки")
    func otherErrorNotRetried() {
        var calls = 0
        #expect(throws: TunnelFailure.noCatalogue) {
            try TunnelPort.launch(nextPort: { 50_000 }, start: { _ in
                calls += 1
                throw TunnelFailure.noCatalogue
            })
        }
        #expect(calls == 1)
    }

    @Test("Попытки ограничены")
    func attemptsBounded() {
        var calls = 0
        #expect(throws: (any Error).self) {
            try TunnelPort.launch(attempts: 3, nextPort: { 50_000 }, start: { _ in
                calls += 1
                throw Busy()
            })
        }
        #expect(calls == 3)
    }

    // MARK: прокси

    @Test("Прокси собирается на loopback с логином и паролем")
    func proxyBuilt() throws {
        let proxy = try #require(TunnelEndpoint.proxy(port: 51_234, user: "u", password: "p"))
        #expect(proxy.host == "127.0.0.1")
        #expect(proxy.port == 51_234)
        #expect(proxy.user == "u")
        #expect(proxy.password == "p")
        #expect(!proxy.description.contains(":p@"))
    }

    @Test("Порт вне диапазона и пустые учётные данные отвергаются")
    func proxyRejected() {
        #expect(TunnelEndpoint.proxy(port: 0, user: "u", password: "p") == nil)
        #expect(TunnelEndpoint.proxy(port: 70_000, user: "u", password: "p") == nil)
        #expect(TunnelEndpoint.proxy(port: -5, user: "u", password: "p") == nil)
        #expect(TunnelEndpoint.proxy(port: 5000, user: "", password: "p") == nil)
        #expect(TunnelEndpoint.proxy(port: 5000, user: "u", password: "") == nil)
    }

    // MARK: путь клиента

    @Test("Пока туннель не поднят или упал, путь не прямой")
    func neverDirectWithoutTunnel() {
        for state in [TunnelState.idle, .starting, .failed(.noFreePort), .failed(.lost)] {
            let route = Route.forTunnel(state)
            #expect(route != .direct)
            guard case .socks5 = route else {
                Issue.record("ожидался закрытый SOCKS-путь")
                continue
            }
        }
    }

    @Test("Поднятый туннель даёт его прокси")
    func routeFollowsProxy() throws {
        let proxy = try #require(TunnelEndpoint.proxy(port: 51_000, user: "u", password: "p"))
        #expect(Route.forTunnel(.up(proxy)) == .socks5(proxy))
    }

    @Test("Закрытый путь без отката на прямое соединение")
    func sealedHasNoFailover() {
        let configuration = Route.sealed.apply(to: URLSessionConfiguration.ephemeral)
        #expect(configuration.proxyConfigurations.count == 1)
        #expect(configuration.proxyConfigurations.first?.allowFailover == false)
    }

    // MARK: клиент за туннелем

    @Test("Клиент следует за путями, пока жив, и не удерживается подпиской")
    func clientFollowsRoutes() async throws {
        let (routes, feed) = AsyncStream<Route>.makeStream()
        var client: MatrixClient? = MatrixClient(homeserver: URL(string: "https://core.nyutag.chat:6167")!,
                                                 route: .sealed)
        let following = try #require(client).follow(routes)
        let proxy = try #require(SocksProxy(port: 50_123, user: "u", password: "p"))
        feed.yield(.socks5(proxy))
        for _ in 0..<200 where await client?.route != .socks5(proxy) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await client?.route == .socks5(proxy))

        weak let gone = client
        client = nil
        #expect(gone == nil)
        feed.yield(.sealed)
        feed.finish()
        await following.value
    }
}
