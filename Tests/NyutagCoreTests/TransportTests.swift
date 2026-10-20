// Транспорт: путь через SOCKS туннеля, пин своего CA, смена пути без пересоздания клиента.
//
// Фикстуры в Fixtures/*.der (DER, только сертификаты, ключей нет). Перегенерация: `Fixtures/make-trust-fixtures.sh`
// (системный openssl; листья 397 дней, проверка идёт на фиксированную дату). Состав:
//   test-ca.der            наш тестовый корень;
//   other-ca.der           чужой корень;
//   leaf-good.der          лист core.test.nyutag от нашего корня;
//   leaf-foreign-root.der  лист core.test.nyutag от чужого корня;
//   leaf-other-host.der    лист elsewhere.test.nyutag от нашего корня.
// public-chain-0..2.der — реальная цепочка example.com (лист, промежуточный, транзитный CA; корень берётся из
// системного хранилища), снятая 2026-10-20 командой
//   openssl s_client -connect example.com:443 -servername example.com -showcerts
// Она нужна, чтобы проверить `SetAnchorCertificatesOnly`: только на цепочке, которой доверяет система, видно,
// что наш пин системным корням не верит. Лист живёт месяцы, поэтому проверка идёт на дату снятия (`verifyDate`).

import Foundation
import Network
import Security
import Testing
@testable import NyutagCore

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "der", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private func certificate(_ name: String) throws -> SecCertificate {
    try #require(SecCertificateCreateWithData(nil, try fixture(name) as CFData))
}

private func trust(chain: [SecCertificate]) throws -> SecTrust {
    var trust: SecTrust?
    #expect(SecTrustCreateWithCertificates(chain as CFArray, SecPolicyCreateBasicX509(), &trust) == errSecSuccess)
    return try #require(trust)
}

private let captureDate = ISO8601DateFormatter().date(from: "2026-10-21T12:00:00Z")!

@Suite("Транспорт: путь")
struct RouteTests {
    @Test("SOCKS: в конфигурации ровно один прокси, порт и логин на месте, откат на прямое запрещён")
    func socksConfiguration() throws {
        let proxy = try #require(SocksProxy(port: 41234, user: "u-test", password: "p-test"))
        let configuration = Route.socks5(proxy).apply(to: MatrixClient.defaultConfiguration())
        #expect(configuration.proxyConfigurations.count == 1)
        let socks = try #require(configuration.proxyConfigurations.first)
        #expect(socks.allowFailover == false)
        #expect(socks.debugDescription.contains("41234"))
        // Исходная конфигурация не тронута, таймауты базы сохранены.
        #expect(configuration.timeoutIntervalForRequest == 60)
    }

    @Test("Прямой путь снимает прокси")
    func directConfiguration() throws {
        let proxy = try #require(SocksProxy(port: 41234, user: "u", password: "p"))
        let base = Route.socks5(proxy).apply(to: MatrixClient.defaultConfiguration())
        #expect(Route.direct.apply(to: base).proxyConfigurations.isEmpty)
        #expect(Route.direct.apply(to: MatrixClient.defaultConfiguration()).proxyConfigurations.isEmpty)
    }

    @Test("Порт 0 и пустой адрес не принимаются, пароль не печатается")
    func proxyValidation() throws {
        #expect(SocksProxy(port: 0, user: "u", password: "p") == nil)
        #expect(SocksProxy(host: "", port: 1, user: "u", password: "p") == nil)
        let proxy = try #require(SocksProxy(port: 5, user: "u", password: "секрет"))
        #expect(!proxy.description.contains("секрет"))
    }
}

@Suite("Транспорт: пин CA")
struct PinTests {
    private func pin() throws -> CertificateTrust {
        CertificateTrust(anchorDER: [try fixture("test-ca")], hosts: ["core.test.nyutag"])
    }

    @Test("Наш CA и верное имя: доверие")
    func ownChainTrusted() throws {
        let t = try trust(chain: [certificate("leaf-good")])
        #expect(try pin().evaluate(t, host: "core.test.nyutag", verifyDate: captureDate))
    }

    @Test("Чужой корень: отказ")
    func foreignRootRejected() throws {
        let t = try trust(chain: [certificate("leaf-foreign-root")])
        #expect(try !pin().evaluate(t, host: "core.test.nyutag", verifyDate: captureDate))
    }

    @Test("Верная цепочка, но другое имя хоста: отказ")
    func wrongHostRejected() throws {
        let good = try trust(chain: [certificate("leaf-good")])
        #expect(try !pin().evaluate(good, host: "elsewhere.test.nyutag", verifyDate: captureDate))
        let other = try trust(chain: [certificate("leaf-other-host")])
        #expect(try !pin().evaluate(other, host: "core.test.nyutag", verifyDate: captureDate))
    }

    @Test("Цепочка, которой верит система, но не наш CA: отказ (якоря только свои)")
    func systemTrustedChainRejected() throws {
        let chain = try (0...2).map { try certificate("public-chain-\($0)") }

        // Контроль: система на дату снятия этой цепочке верит, иначе проверка ничего бы не доказывала.
        let control = try trust(chain: chain)
        #expect(SecTrustSetPolicies(control, SecPolicyCreateSSL(true, "example.com" as CFString)) == errSecSuccess)
        #expect(SecTrustSetVerifyDate(control, captureDate as CFDate) == errSecSuccess)
        var error: CFError?
        #expect(SecTrustEvaluateWithError(control, &error), "системное доверие к public-chain: \(String(describing: error))")

        let t = try trust(chain: chain)
        #expect(try !pin().evaluate(t, host: "example.com", verifyDate: captureDate))
    }

    @Test("Без якорей доверия нет")
    func noAnchors() throws {
        let t = try trust(chain: [certificate("leaf-good")])
        #expect(!CertificateTrust(anchorDER: [], hosts: []).evaluate(t, host: "core.test.nyutag", verifyDate: captureDate))
    }

    @Test("Встроенный CA ядра раскодируется и закреплён за core.nyutag.chat")
    func builtInAnchor() {
        let trust = CertificateTrust.nyutagCore()
        #expect(trust.anchors.count == 1)
        #expect(trust.hosts == ["core.nyutag.chat"])
    }
}

/// Заглушка сети: отвечает 200 и пишет, сколько запросов дошло.
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var hits = 0
    private static let lock = NSLock()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.hits += 1 }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Транспорт: смена пути", .serialized)
struct RouteSwitchTests {
    private func makeClient(route: Route = .direct) -> MatrixClient {
        let configuration = MatrixClient.defaultConfiguration()
        configuration.protocolClasses = [StubProtocol.self]
        return MatrixClient(homeserver: URL(string: "https://core.test.nyutag:6167")!, accessToken: "tok",
                            configuration: configuration, route: route)
    }

    @Test("setRoute подменяет сеанс внутри того же клиента, база (заглушка) сохраняется")
    func switchKeepsClient() async throws {
        let client = makeClient()
        #expect(await client.route == .direct)
        #expect(await client.session.configuration.proxyConfigurations.isEmpty)

        let first = try #require(SocksProxy(port: 30001, user: "a", password: "b"))
        await client.setRoute(.socks5(first))
        #expect(await client.session.configuration.proxyConfigurations.count == 1)
        #expect(await client.session.configuration.proxyConfigurations.first?.debugDescription.contains("30001") == true)

        let second = try #require(SocksProxy(port: 30002, user: "c", password: "d"))
        await client.setRoute(.socks5(second))
        #expect(await client.session.configuration.proxyConfigurations.first?.debugDescription.contains("30002") == true)
        #expect(await client.route == .socks5(second))

        let before = StubProtocol.hits
        let _: EmptyResponse = try await client.raw(.get, "/_nyutag/v1/ping")
        #expect(StubProtocol.hits == before + 1, "после смены пути запросы идут и заглушка базы не потеряна")

        await client.setRoute(.direct)
        #expect(await client.session.configuration.proxyConfigurations.isEmpty)
    }

    @Test("Тот же путь: сеанс не пересоздаётся")
    func sameRouteNoop() async throws {
        let proxy = try #require(SocksProxy(port: 30003, user: "a", password: "b"))
        let client = makeClient(route: .socks5(proxy))
        let before = await client.session
        await client.setRoute(.socks5(proxy))
        #expect(await client.session === before)
    }

    @Test("Клиент без пути работает как раньше")
    func plainClient() async throws {
        let configuration = MatrixClient.defaultConfiguration()
        configuration.protocolClasses = [StubProtocol.self]
        let client = MatrixClient(homeserver: URL(string: "https://x.test")!, accessToken: "t", configuration: configuration)
        let _: EmptyResponse = try await client.raw(.get, "/ping")
    }
}
