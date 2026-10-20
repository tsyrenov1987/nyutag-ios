import Foundation
@testable import NyutagCore
import Testing

/// Маленький стаб сервера: у каждого теста свой хост, поэтому параллельные тесты не мешают друг другу.
private final class DirectoryStub: @unchecked Sendable {
    struct Recorded {
        let method: String
        let path: String
        let query: [String: String]
        let body: JSONValue?
        let auth: String?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [String: DirectoryStub] = [:]

    let host = "dir-\(UUID().uuidString.lowercased()).test"
    private let state = NSLock()
    private var _requests: [Recorded] = []
    private let status: Int
    private let response: JSONValue

    init(status: Int = 200, response: JSONValue = [:]) {
        self.status = status
        self.response = response
        Self.lock.withLock { Self.stubs[host] = self }
    }

    deinit { Self.lock.withLock { _ = Self.stubs.removeValue(forKey: host) } }

    var requests: [Recorded] { state.withLock { _requests } }
    var last: Recorded? { requests.last }

    func client() -> MatrixClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DirectoryStubProtocol.self]
        return MatrixClient(homeserver: URL(string: "https://\(host)")!, accessToken: "tok", configuration: configuration)
    }

    static func stub(host: String) -> DirectoryStub? { lock.withLock { stubs[host] } }

    func handle(_ recorded: Recorded) -> (Int, JSONValue) {
        state.withLock { _requests.append(recorded) }
        return (status, response)
    }
}

private final class DirectoryStubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let stub = DirectoryStub.stub(host: url.host ?? "") else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        var bodyData = request.httpBody
        if bodyData == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            bodyData = data
        }
        let query = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        let recorded = DirectoryStub.Recorded(
            method: request.httpMethod ?? "GET",
            // percentEncodedPath: проверяем, что `!`, `:`, `#` ушли закодированными.
            path: URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path,
            query: query,
            body: bodyData.flatMap { $0.isEmpty ? nil : try? JSONValue(data: $0) },
            auth: request.value(forHTTPHeaderField: "Authorization"))
        let (status, json) = stub.handle(recorded)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? json.data()) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
}

struct DirectoryTests {
    private static let publicRoomsJSON = #"""
    {"chunk":[
      {"room_id":"!sp:nyutag.chat","name":"Буряад хэлэн","topic":"Сообщество","canonical_alias":"#buryad:nyutag.chat",
       "avatar_url":"mxc://nyutag.chat/abc123","num_joined_members":42,"world_readable":true,"guest_can_join":false,
       "join_rule":"public","room_type":"m.space"},
      {"room_id":"!plain:nyutag.chat","num_joined_members":3,"world_readable":false,"guest_can_join":true},
      {"name":"без room_id"}
    ],"next_batch":"n1","prev_batch":"p1","total_room_count_estimate":115}
    """#

    @Test func publicRoomsParsing() async throws {
        let stub = DirectoryStub(response: try JSONValue(parsing: Self.publicRoomsJSON))
        let page = try await stub.client().publicRooms(limit: 20)
        #expect(page.rooms.count == 2)
        let space = try #require(page.rooms.first)
        #expect(space.roomID == "!sp:nyutag.chat")
        #expect(space.name == "Буряад хэлэн")
        #expect(space.topic == "Сообщество")
        #expect(space.canonicalAlias == "#buryad:nyutag.chat")
        #expect(space.avatarURL == MXC("mxc://nyutag.chat/abc123"))
        #expect(space.numJoinedMembers == 42)
        #expect(space.worldReadable)
        #expect(!space.guestCanJoin)
        #expect(space.joinRule == "public")
        #expect(space.isSpace)
        let plain = page.rooms[1]
        #expect(plain.name == nil && plain.avatarURL == nil && plain.roomType == nil)
        #expect(plain.guestCanJoin && !plain.isSpace)
        #expect(page.nextBatch == "n1" && page.prevBatch == "p1" && page.totalRoomCountEstimate == 115)
    }

    @Test func publicRoomsRequestShape() async throws {
        let stub = DirectoryStub(response: ["chunk": []])
        let filter = PublicRoomsFilter(genericSearchTerm: "бурятия", roomTypes: ["m.space", nil])
        _ = try await stub.client().publicRooms(server: "other.example", limit: 10, since: "tok1", filter: filter,
                                                includeAllNetworks: true)
        let request = try #require(stub.last)
        #expect(request.method == "POST")
        #expect(request.path == "/_matrix/client/v3/publicRooms")
        #expect(request.query == ["server": "other.example"])
        #expect(request.body?["limit"]?.int == 10)
        #expect(request.body?["since"]?.string == "tok1")
        #expect(request.body?["include_all_networks"]?.bool == true)
        #expect(request.body?["filter", "generic_search_term"]?.string == "бурятия")
        #expect(request.body?["filter", "room_types"] == .array([.string("m.space"), .null]))
        #expect(request.auth == "Bearer tok")
    }

    @Test func publicRoomsMinimalBodyOmitsOptionals() async throws {
        let stub = DirectoryStub(response: ["chunk": []])
        _ = try await stub.client().publicRooms()
        let request = try #require(stub.last)
        #expect(request.query.isEmpty)
        #expect(request.body == [:])
    }

    @Test func communitiesFilterIsSpaceOnly() async throws {
        let stub = DirectoryStub(response: ["chunk": []])
        _ = try await stub.client().publicCommunities(search: "нютаг")
        let request = try #require(stub.last)
        #expect(request.body?["filter", "room_types"] == .array([.string("m.space")]))
        #expect(request.body?["filter", "generic_search_term"]?.string == "нютаг")
    }

    @Test func publicRoomsWithoutChunkIsDecodingError() async {
        let stub = DirectoryStub(response: ["next_batch": "x"])
        await #expect(throws: MatrixError.self) { try await stub.client().publicRooms() }
    }

    @Test func hierarchyParsingAndRequest() async throws {
        let json = try JSONValue(parsing: #"""
        {"rooms":[
          {"room_id":"!sp:x","name":"Space","num_joined_members":5,"world_readable":false,"guest_can_join":false,
           "room_type":"m.space","join_rule":"public",
           "children_state":[
             {"type":"m.space.child","state_key":"!a:x","sender":"@o:x","origin_server_ts":1700,
              "content":{"via":["x","y"],"suggested":true,"order":"01"}},
             {"type":"m.space.child","state_key":"!b:x","sender":"@o:x","origin_server_ts":1701,"content":{"via":["x"]}},
             {"type":"m.room.member","state_key":"@u:x","content":{}}
           ]},
          {"room_id":"!a:x","name":"A","num_joined_members":2,"world_readable":false,"guest_can_join":false,
           "children_state":[]}
        ],"next_batch":"hb"}
        """#)
        let stub = DirectoryStub(response: json)
        let page = try await stub.client().roomHierarchy(roomID: "!sp:x", from: "h0", limit: 5, maxDepth: 2,
                                                         suggestedOnly: true)
        let request = try #require(stub.last)
        #expect(request.method == "GET")
        #expect(request.path == "/_matrix/client/v1/rooms/%21sp%3Ax/hierarchy")
        #expect(request.query == ["from": "h0", "limit": "5", "max_depth": "2", "suggested_only": "true"])
        #expect(page.nextBatch == "hb")
        #expect(page.rooms.count == 2)
        let root = page.rooms[0]
        #expect(root.room.isSpace)
        #expect(root.childrenState.count == 2) // чужой тип события отброшен
        #expect(root.childrenState[0].roomID == "!a:x")
        #expect(root.childrenState[0].via == ["x", "y"])
        #expect(root.childrenState[0].suggested)
        #expect(root.childrenState[0].order == "01")
        #expect(root.childrenState[0].sender == "@o:x")
        #expect(root.childrenState[0].originServerTS == 1700)
        #expect(!root.childrenState[1].suggested && root.childrenState[1].order == nil)
        #expect(page.rooms[1].childrenState.isEmpty)
    }

    @Test func hierarchyDefaultsHaveNoQuery() async throws {
        let stub = DirectoryStub(response: ["rooms": []])
        _ = try await stub.client().roomHierarchy(roomID: "!sp:x")
        #expect(stub.last?.query.isEmpty == true)
    }

    @Test func knockRequestAndResponse() async throws {
        let stub = DirectoryStub(response: ["room_id": "!k:x"])
        let id = try await stub.client().knock("#club:x", reason: "Пустите", via: ["x", "y"])
        #expect(id == "!k:x")
        let request = try #require(stub.last)
        #expect(request.method == "POST")
        #expect(request.path == "/_matrix/client/v3/knock/%23club%3Ax")
        #expect(request.query == ["via": "x", "server_name": "x"])
        #expect(request.body == ["reason": "Пустите"])
    }

    @Test func knockWithoutViaAndReason() async throws {
        let stub = DirectoryStub(response: ["room_id": "!k:x"])
        _ = try await stub.client().knock("!k:x")
        let request = try #require(stub.last)
        #expect(request.query.isEmpty)
        #expect(request.body == [:])
    }

    @Test func serverErrorIsPropagated() async {
        let stub = DirectoryStub(status: 403, response: ["errcode": "M_FORBIDDEN", "error": "no"])
        do {
            _ = try await stub.client().knock("!k:x")
            Issue.record("ждали ошибку")
        } catch {
            #expect(error.errcode == "M_FORBIDDEN")
            #expect(error.status == 403)
        }
    }

    @Test func resolveAliasIsUnauthenticated() async throws {
        let stub = DirectoryStub(response: ["room_id": "!r:x", "servers": ["x", "y"]])
        let result = try await stub.client().resolveAlias("#club:x")
        #expect(result.roomID == "!r:x")
        #expect(result.servers == ["x", "y"])
        let request = try #require(stub.last)
        #expect(request.method == "GET")
        #expect(request.path == "/_matrix/client/v3/directory/room/%23club%3Ax")
        #expect(request.auth == nil)
    }

    @Test func roomVisibility() async throws {
        let getStub = DirectoryStub(response: ["visibility": "public"])
        #expect(try await getStub.client().roomVisibility(roomID: "!r:x") == "public")
        #expect(getStub.last?.method == "GET")
        #expect(getStub.last?.path == "/_matrix/client/v3/directory/list/room/%21r%3Ax")

        let putStub = DirectoryStub()
        try await putStub.client().setRoomVisibility(roomID: "!r:x", public: false)
        let request = try #require(putStub.last)
        #expect(request.method == "PUT")
        #expect(request.path == "/_matrix/client/v3/directory/list/room/%21r%3Ax")
        #expect(request.body == ["visibility": "private"])
        #expect(request.auth == "Bearer tok")
    }

    @Test func spaceChildHelpers() async throws {
        let stub = DirectoryStub(response: ["event_id": "$e"])
        let client = stub.client()
        try await client.addSpaceChild(spaceID: "!sp:x", childID: "!c:x", via: ["x"], suggested: true, order: "a")
        var request = try #require(stub.last)
        #expect(request.method == "PUT")
        #expect(request.path == "/_matrix/client/v3/rooms/%21sp%3Ax/state/m.space.child/%21c%3Ax")
        #expect(request.body == ["via": ["x"], "suggested": true, "order": "a"])

        try await client.addSpaceChild(spaceID: "!sp:x", childID: "!c:x", via: ["x"])
        #expect(stub.last?.body == ["via": ["x"]])

        try await client.removeSpaceChild(spaceID: "!sp:x", childID: "!c:x")
        request = try #require(stub.last)
        #expect(request.path == "/_matrix/client/v3/rooms/%21sp%3Ax/state/m.space.child/%21c%3Ax")
        #expect(request.body == [:])
    }

    @Test func spaceParentHelpers() async throws {
        let stub = DirectoryStub(response: ["event_id": "$e"])
        let client = stub.client()
        try await client.setSpaceParent(roomID: "!c:x", spaceID: "!sp:x", via: ["x"], canonical: true)
        var request = try #require(stub.last)
        #expect(request.path == "/_matrix/client/v3/rooms/%21c%3Ax/state/m.space.parent/%21sp%3Ax")
        #expect(request.body == ["via": ["x"], "canonical": true])

        try await client.removeSpaceParent(roomID: "!c:x", spaceID: "!sp:x")
        request = try #require(stub.last)
        #expect(request.path == "/_matrix/client/v3/rooms/%21c%3Ax/state/m.space.parent/%21sp%3Ax")
        #expect(request.body == [:])
    }
}
