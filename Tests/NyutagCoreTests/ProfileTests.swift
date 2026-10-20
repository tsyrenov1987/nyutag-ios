import Foundation
@testable import NyutagCore
import Testing

// Свой маленький стаб сервера: каждый тест получает уникальный хост, обработчик лежит под этим хостом,
// поэтому параллельные тесты друг другу не мешают.

private struct Recorded: Sendable {
    let method: String
    let path: String
    let body: JSONValue?
}

private final class ProfileStub: @unchecked Sendable {
    typealias Handler = @Sendable (Recorded) -> (status: Int, body: String)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

    let host = "stub-\(UUID().uuidString.lowercased()).test"

    init(_ handler: @escaping Handler) {
        Self.lock.withLock { Self.handlers[host] = handler }
    }

    deinit { Self.lock.withLock { _ = Self.handlers.removeValue(forKey: host) } }

    fileprivate static func handler(for host: String) -> Handler? { lock.withLock { handlers[host] } }

    func client() -> MatrixClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProfileStubProtocol.self]
        return MatrixClient(homeserver: URL(string: "https://\(host)")!, accessToken: "tok", configuration: configuration)
    }
}

private final class ProfileStubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host, let handler = ProfileStub.handler(for: host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        var data = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
        } else if let body = request.httpBody {
            data = body
        }
        let recorded = Recorded(method: request.httpMethod ?? "", path: url.path(percentEncoded: false),
                                body: data.isEmpty ? nil : try? JSONValue(data: data))
        let result = handler(recorded)
        let response = HTTPURLResponse(url: url, statusCode: result.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(result.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Стаб, который сам пишет журнал запросов и хранит состояние account data для m.direct.
private final class Server: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [Recorded] = []
    private var accountData: [String: JSONValue] = [:]
    private(set) var stub: ProfileStub!
    private let onRequest: @Sendable (Recorded, Server) -> (status: Int, body: String)

    init(accountData: [String: JSONValue] = [:],
         onRequest: @escaping @Sendable (Recorded, Server) -> (status: Int, body: String)) {
        self.accountData = accountData
        self.onRequest = onRequest
        stub = ProfileStub { [unowned self] request in
            lock.withLock { log.append(request) }
            return self.onRequest(request, self)
        }
    }

    var requests: [Recorded] { lock.withLock { log } }
    func data(_ type: String) -> JSONValue? { lock.withLock { accountData[type] } }
    func setData(_ type: String, _ value: JSONValue) { lock.withLock { accountData[type] = value } }
    func client() -> MatrixClient { stub.client() }
}

private let ok = (status: 200, body: "{}")
private let notFound = (status: 404, body: #"{"errcode":"M_NOT_FOUND","error":"нет"}"#)
private let me = "@me:nyutag.chat"
private let other = "@sayan:nyutag.chat"

struct ProfileTests {
    // MARK: Профиль

    @Test func fullProfileParsing() async throws {
        let server = Server { _, _ in
            (200, #"{"displayname":"Саян","avatar_url":"mxc://x/a","chat.nyutag.about":"привет","chat.nyutag.ug":""}"#)
        }
        let client = server.client()
        let profile = try await client.profile(userID: other)
        #expect(profile.displayName == "Саян")
        #expect(profile.avatarURL == "mxc://x/a")
        #expect(profile[.about] == "привет")
        #expect(profile[.ug] == nil)
        #expect(profile[.toonto] == nil)
        let request = server.requests[0]
        #expect(request.method == "GET")
        #expect(request.path == "/_matrix/client/v3/profile/@sayan:nyutag.chat")
    }

    @Test func missingProfileIsEmpty() async throws {
        let server = Server { _, _ in notFound }
        let profile = try await server.client().profile(userID: other)
        #expect(profile == Profile())
    }

    @Test func displayNameAndAvatarPaths() async throws {
        let server = Server { _, _ in ok }
        let client = server.client()
        try await client.setDisplayName(userID: me, "Нютаг")
        try await client.setAvatarURL(userID: me, "mxc://x/b")
        let requests = server.requests
        #expect(requests[0].method == "PUT")
        #expect(requests[0].path == "/_matrix/client/v3/profile/@me:nyutag.chat/displayname")
        #expect(requests[0].body == ["displayname": .string("Нютаг")])
        #expect(requests[1].path == "/_matrix/client/v3/profile/@me:nyutag.chat/avatar_url")
        #expect(requests[1].body == ["avatar_url": .string("mxc://x/b")])
    }

    @Test func capabilitiesChooseAPI() throws {
        func api(_ json: String) throws -> ProfileFieldsAPI { ProfileFieldsAPI(capabilities: try JSONValue(parsing: json)) }
        #expect(try api(#"{"capabilities":{"m.profile_fields":{"enabled":true}}}"#) == .stable)
        #expect(try api(#"{"capabilities":{"uk.tcpip.msc4133.profile_fields":{"enabled":true}}}"#) == .unstable)
        #expect(try api(#"{"capabilities":{"m.profile_fields":{"enabled":false}}}"#) == .disabled)
        #expect(try api(#"{"capabilities":{"m.change_password":{"enabled":true}}}"#) == .stable)
        // Стабильная возможность важнее нестабильной.
        #expect(try api(#"{"capabilities":{"m.profile_fields":{"enabled":true},"uk.tcpip.msc4133.profile_fields":{"enabled":true}}}"#) == .stable)
    }

    @Test func capabilitiesRequestIsRead() async throws {
        let server = Server { _, _ in (200, #"{"capabilities":{"uk.tcpip.msc4133.profile_fields":{"enabled":true}}}"#) }
        let api = try await server.client().profileFieldsAPI()
        #expect(api == .unstable)
        #expect(server.requests[0].path == "/_matrix/client/v3/capabilities")
    }

    @Test func stableFieldPathAndBody() async throws {
        let server = Server { _, _ in ok }
        let client = server.client()
        try await client.setProfileField(userID: me, key: NyutagProfileKey.toonto.rawValue, value: "Хубсугул")
        let request = server.requests[0]
        #expect(request.method == "PUT")
        #expect(request.path == "/_matrix/client/v3/profile/@me:nyutag.chat/chat.nyutag.toonto")
        #expect(request.body == ["chat.nyutag.toonto": .string("Хубсугул")])
    }

    @Test func unstableFieldPath() async throws {
        let server = Server { _, _ in ok }
        try await server.client().setProfileField(userID: me, key: "chat.nyutag.about", value: "x", api: .unstable)
        #expect(server.requests[0].path == "/_matrix/client/unstable/uk.tcpip.msc4133/profile/@me:nyutag.chat/chat.nyutag.about")
    }

    @Test func disabledFieldsAreRefusedWithoutRequest() async throws {
        let server = Server { _, _ in ok }
        await #expect(throws: MatrixError.self) {
            try await server.client().setProfileField(userID: me, key: "k", value: "v", api: .disabled)
        }
        #expect(server.requests.isEmpty)
    }

    @Test func deleteFieldTolerates404() async throws {
        let server = Server { _, _ in notFound }
        try await server.client().deleteProfileField(userID: me, key: "chat.nyutag.ug")
        #expect(server.requests[0].method == "DELETE")
        #expect(server.requests[0].path == "/_matrix/client/v3/profile/@me:nyutag.chat/chat.nyutag.ug")
    }

    @Test func editsWriteAndDeleteInKeyOrder() async throws {
        let server = Server { _, _ in ok }
        try await server.client().applyProfileEdits(userID: me, [.about: "стало", .ug: nil, .toonto: ""], api: .stable)
        let requests = server.requests
        #expect(requests.map(\.method) == ["PUT", "DELETE", "DELETE"])
        #expect(requests.map { String($0.path.split(separator: "/").last ?? "") }
                == ["chat.nyutag.about", "chat.nyutag.toonto", "chat.nyutag.ug"])
        #expect(requests[0].body == ["chat.nyutag.about": .string("стало")])
    }

    // MARK: m.direct

    private func directServer(initial: JSONValue?, createdRoom: String = "!new:nyutag.chat") -> Server {
        let server = Server { request, server in
            if request.path.hasSuffix("/account_data/m.direct") {
                if request.method == "GET" {
                    guard let value = server.data("m.direct") else { return notFound }
                    return (200, String(decoding: (try? value.data()) ?? Data(), as: UTF8.self))
                }
                if request.method == "PUT", let body = request.body { server.setData("m.direct", body) }
                return ok
            }
            if request.path.hasSuffix("/createRoom") { return (200, #"{"room_id":"\#(createdRoom)"}"#) }
            return notFound
        }
        if let initial { server.setData("m.direct", initial) }
        return server
    }

    @Test func missingDirectIsEmptyDictionary() async throws {
        let server = directServer(initial: nil)
        let rooms = try await server.client().directRooms(userID: me)
        #expect(rooms.isEmpty)
        #expect(server.requests[0].path == "/_matrix/client/v3/user/@me:nyutag.chat/account_data/m.direct")
    }

    @Test func directParsingAndLookup() async throws {
        let server = directServer(initial: ["@a:x": ["!1:x", "!2:x"], "@b:x": ["!3:x"], "@bad:x": "не массив"])
        let client = server.client()
        let rooms = try await client.directRooms(userID: me)
        #expect(rooms["@a:x"] == ["!1:x", "!2:x"])
        #expect(rooms["@bad:x"] == [])
        #expect(try await client.directRoom(userID: me, with: "@b:x") == "!3:x")
        #expect(try await client.directRoom(userID: me, with: "@nobody:x") == nil)
    }

    @Test func addDirectKeepsOthersEntries() async throws {
        let server = directServer(initial: ["@a:x": ["!1:x"], "@b:x": ["!3:x"], "@sayan:nyutag.chat": ["!old:x"]])
        try await server.client().addDirectRoom(userID: me, with: other, roomID: "!new:x")
        let saved = try #require(server.data("m.direct"))
        #expect(saved["@a:x"] == ["!1:x"])
        #expect(saved["@b:x"] == ["!3:x"])
        #expect(saved[other] == ["!old:x", "!new:x"])
    }

    @Test func addDirectToMissingAccountData() async throws {
        let server = directServer(initial: nil)
        try await server.client().addDirectRoom(userID: me, with: other, roomID: "!new:x")
        #expect(server.data("m.direct") == [other: ["!new:x"]])
    }

    @Test func addDirectIsIdempotent() async throws {
        let server = directServer(initial: [other: ["!new:x"]])
        try await server.client().addDirectRoom(userID: me, with: other, roomID: "!new:x")
        #expect(!server.requests.contains { $0.method == "PUT" })
    }

    @Test func createDirectRoomEncrypted() async throws {
        let server = directServer(initial: ["@a:x": ["!1:x"]])
        let roomID = try await server.client().createDirectRoom(userID: me, with: other)
        #expect(roomID == "!new:nyutag.chat")
        let create = try #require(server.requests.first { $0.path.hasSuffix("/createRoom") })
        #expect(create.method == "POST")
        let body = try #require(create.body)
        #expect(body["is_direct"]?.bool == true)
        #expect(body["preset"]?.string == "trusted_private_chat")
        #expect(body["invite"] == [.string(other)])
        #expect(body["initial_state"]?[0]?["type"]?.string == "m.room.encryption")
        let saved = try #require(server.data("m.direct"))
        #expect(saved["@a:x"] == ["!1:x"])
        #expect(saved[other] == ["!new:nyutag.chat"])
    }

    @Test func createDirectRoomUnencrypted() async throws {
        let server = directServer(initial: nil)
        try await server.client().createDirectRoom(userID: me, with: other, encrypted: false)
        let create = try #require(server.requests.first { $0.path.hasSuffix("/createRoom") })
        #expect(create.body?["initial_state"] == nil)
        #expect(create.body?["is_direct"]?.bool == true)
    }
}
