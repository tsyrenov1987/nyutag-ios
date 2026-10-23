// Пробуждение синхронизации: длинный запрос, повисший на мёртвом после сна соединении, не держит входящий
// звонок — wake() начинает запрос заново.

import Foundation
@testable import NyutagCore
import Testing

/// Первый /sync не отвечает никогда (как соединение, умершее во сне), следующие отвечают сразу.
final class HangingSyncProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) static var requests = 0

    override class func canInit(with request: URLRequest) -> Bool { request.url?.path.hasSuffix("/sync") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let number = Self.lock.withLock { Self.requests += 1; return Self.requests }
        guard number > 1 else { return }
        let body = Data(#"{"next_batch":"s\#(number)"}"#.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct SyncWakeTests {
    @Test func wakeRestartsHungLongPoll() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HangingSyncProtocol.self]
        let homeserver = URL(string: "http://sync-wake.test")!
        let client = MatrixClient(homeserver: homeserver, accessToken: "t", configuration: configuration)
        let store = try Store.inMemory()
        let session = Session(userID: "@a:nyutag.chat", deviceID: "D", accessToken: "t", homeserver: homeserver)
        let engine = SyncEngine(client: client, store: store, session: session)
        await engine.start()
        let clock = ContinuousClock()
        var deadline = clock.now + .seconds(5)
        while HangingSyncProtocol.requests < 1, clock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await store.syncToken == nil)

        await engine.wake()
        deadline = clock.now + .seconds(3)
        while try await store.syncToken == nil, clock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        await engine.stop()
        #expect(try await store.syncToken != nil)
    }
}
