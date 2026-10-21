// Транспорт: клиент с дверью. Адрес запроса — дверь, имя ядра остаётся в сессии; ключ двери в заголовке;
// смена двери без пересоздания клиента; ожидание двери; жалоба на дверь, которая не отвечает.

import Foundation
import Testing
@testable import NyutagCore

/// Заглушка сети: отвечает заданным статусом и запоминает последний запрос.
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _last: URLRequest?
    nonisolated(unsafe) private static var _status = 200
    nonisolated(unsafe) private static var _hits = 0
    static var last: URLRequest? { lock.withLock { _last } }
    static var hits: Int { lock.withLock { _hits } }
    static func answer(_ status: Int) { lock.withLock { _status = status } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = Self.lock.withLock { Self._last = request; Self._hits += 1; return Self._status }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private let core = URL(string: "https://core.test.nyutag")!
private let doorA = Door(line: "https://a.test.nyutag:6167#a")!
private let doorB = Door(line: "https://b.test.nyutag#b")!

private func makeClient(doorKey: String? = "k-test", door: Door? = nil, doorWait: Duration = .seconds(20)) -> MatrixClient {
    let configuration = MatrixClient.defaultConfiguration()
    configuration.protocolClasses = [StubProtocol.self]
    return MatrixClient(homeserver: core, accessToken: "tok", configuration: configuration,
                        doorKey: doorKey, door: door, doorWait: doorWait)
}

@Suite("Транспорт: дверь", .serialized)
struct DoorTransportTests {
    init() { StubProtocol.answer(200) }

    @Test("Запрос идёт на дверь с ключом в заголовке, имя ядра в адрес не попадает")
    func requestGoesThroughDoor() async throws {
        let client = makeClient(door: doorA)
        let _: EmptyResponse = try await client.raw(.get, "/_nyutag/v1/ping")
        let request = try #require(StubProtocol.last)
        #expect(request.url?.host() == "a.test.nyutag")
        #expect(request.url?.port == 6167)
        #expect(request.url?.path() == "/_nyutag/v1/ping")
        #expect(request.value(forHTTPHeaderField: DoorCatalogue.headerName) == "k-test")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(client.homeserver == core, "имя ядра для сессии не меняется")
    }

    @Test("Без ключа клиент ходит на homeserver и заголовка двери не ставит")
    func plainClient() async throws {
        let client = makeClient(doorKey: nil)
        let _: EmptyResponse = try await client.raw(.get, "/ping")
        let request = try #require(StubProtocol.last)
        #expect(request.url?.host() == "core.test.nyutag")
        #expect(request.value(forHTTPHeaderField: DoorCatalogue.headerName) == nil)
    }

    @Test("setDoor меняет адрес внутри того же клиента, сеанс не пересоздаётся")
    func switchKeepsClient() async throws {
        let client = makeClient(door: doorA)
        let session = await client.session
        await client.setDoor(doorB)
        #expect(await client.door == doorB)
        let _: EmptyResponse = try await client.raw(.get, "/ping")
        #expect(StubProtocol.last?.url?.host() == "b.test.nyutag")
        #expect(StubProtocol.last?.url?.port == nil)
        #expect(await client.session === session)
    }

    @Test("Нет двери: запрос ждёт, setDoor его отпускает")
    func waitsForDoor() async throws {
        let client = makeClient()
        let clock = ContinuousClock(), started = clock.now
        let pending = Task { () throws -> Void in let _: EmptyResponse = try await client.raw(.get, "/ping") }
        try await Task.sleep(for: .milliseconds(400))
        await client.setDoor(doorA)
        try await pending.value
        #expect(clock.now - started >= .milliseconds(400))
        #expect(StubProtocol.last?.url?.host() == "a.test.nyutag")
    }

    @Test("Нет двери и ждать нельзя: ошибка сети сразу, к ядру напрямую не ходим")
    func noDoorNoWait() async {
        let before = StubProtocol.hits
        let client = makeClient(doorWait: .zero)
        await #expect(throws: MatrixError(.network("нет пути к ядру"))) {
            let _: EmptyResponse = try await client.raw(.get, "/ping")
        }
        #expect(StubProtocol.hits == before)
    }

    @Test("Ожидание истекло: ошибка сети")
    func doorWaitExpires() async {
        let client = makeClient(doorWait: .milliseconds(300))
        await #expect(throws: MatrixError(.network("нет пути к ядру"))) {
            let _: EmptyResponse = try await client.raw(.get, "/ping")
        }
    }

    @Test("502 от двери: жалоба на неё; на сменившуюся за время полёта дверь жалобы нет")
    func complainsOnBadGateway() async throws {
        let client = makeClient(door: doorA)
        let complaints = Complaints()
        await client.setDoorTrouble { complaints.add($0) }
        StubProtocol.answer(502)
        await #expect(throws: MatrixError.self) { let _: EmptyResponse = try await client.raw(.get, "/ping") }
        #expect(complaints.all == [doorA])
        StubProtocol.answer(200)
        let _: EmptyResponse = try await client.raw(.get, "/ping")
        #expect(complaints.all == [doorA], "удачный ответ жалоб не добавляет")
    }

    @Test("Беда двери или всей сети")
    func doorTroubleTable() {
        #expect(MatrixClient.isDoorTrouble(URLError(.timedOut)))
        #expect(MatrixClient.isDoorTrouble(URLError(.cannotConnectToHost)))
        #expect(MatrixClient.isDoorTrouble(URLError(.secureConnectionFailed)))
        #expect(MatrixClient.isDoorTrouble(URLError(.networkConnectionLost)))
        #expect(!MatrixClient.isDoorTrouble(URLError(.cancelled)))
        #expect(!MatrixClient.isDoorTrouble(URLError(.notConnectedToInternet)))
        #expect(!MatrixClient.isDoorTrouble(URLError(.dataNotAllowed)))
    }

    @Test("follow: клиент берёт двери из потока")
    func followsStream() async throws {
        let client = makeClient()
        let (stream, continuation) = AsyncStream<Door?>.makeStream()
        client.follow(stream)
        continuation.yield(doorB)
        for _ in 0..<40 where await client.door == nil { try await Task.sleep(for: .milliseconds(25)) }
        #expect(await client.door == doorB)
        continuation.yield(nil)
        for _ in 0..<40 where await client.door != nil { try await Task.sleep(for: .milliseconds(25)) }
        #expect(await client.door == nil)
        continuation.finish()
    }
}

private final class Complaints: @unchecked Sendable {
    private let lock = NSLock()
    private var doors: [Door] = []
    func add(_ door: Door) { lock.withLock { doors.append(door) } }
    var all: [Door] { lock.withLock { doors } }
}
