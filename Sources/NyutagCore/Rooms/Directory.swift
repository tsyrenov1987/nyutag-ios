// Нютаг. Каталог комнат, пространства (spaces) и knock. Сообщества Нютага — это комнаты типа `m.space`.
// Форматы по спецификации Matrix CS API v1.12: /publicRooms, /rooms/{id}/hierarchy, /knock, /directory.

import Foundation

/// Запись каталога (`PublicRoomsChunk`). Для обязательных по спеке полей без значения берём безопасный ноль.
public struct PublicRoom: Sendable, Equatable {
    public let roomID: String
    public let name: String?
    public let topic: String?
    public let canonicalAlias: String?
    public let avatarURL: MXC?
    public let numJoinedMembers: Int
    public let worldReadable: Bool
    public let guestCanJoin: Bool
    public let joinRule: String?
    /// `m.space` для сообщества, `nil` для обычной комнаты.
    public let roomType: String?

    public var isSpace: Bool { roomType == "m.space" }

    public init(roomID: String, name: String? = nil, topic: String? = nil, canonicalAlias: String? = nil,
                avatarURL: MXC? = nil, numJoinedMembers: Int = 0, worldReadable: Bool = false,
                guestCanJoin: Bool = false, joinRule: String? = nil, roomType: String? = nil) {
        self.roomID = roomID
        self.name = name
        self.topic = topic
        self.canonicalAlias = canonicalAlias
        self.avatarURL = avatarURL
        self.numJoinedMembers = numJoinedMembers
        self.worldReadable = worldReadable
        self.guestCanJoin = guestCanJoin
        self.joinRule = joinRule
        self.roomType = roomType
    }

    /// `nil`, если нет `room_id`.
    init?(json: JSONValue) {
        guard let roomID = json["room_id"]?.string else { return nil }
        self.init(roomID: roomID,
                  name: json["name"]?.string,
                  topic: json["topic"]?.string,
                  canonicalAlias: json["canonical_alias"]?.string,
                  avatarURL: json["avatar_url"]?.string.flatMap { MXC($0) },
                  numJoinedMembers: json["num_joined_members"]?.int ?? 0,
                  worldReadable: json["world_readable"]?.bool ?? false,
                  guestCanJoin: json["guest_can_join"]?.bool ?? false,
                  joinRule: json["join_rule"]?.string,
                  roomType: json["room_type"]?.string)
    }
}

/// Фильтр каталога (`Filter` в теле POST /publicRooms).
public struct PublicRoomsFilter: Sendable, Equatable {
    public var genericSearchTerm: String?
    /// Типы комнат; `nil` внутри массива — комнаты без типа. `nil` целиком — без фильтра по типу.
    public var roomTypes: [String?]?

    public init(genericSearchTerm: String? = nil, roomTypes: [String?]? = nil) {
        self.genericSearchTerm = genericSearchTerm
        self.roomTypes = roomTypes
    }

    /// Только сообщества Нютага (`m.space`).
    public static func communities(searching term: String? = nil) -> PublicRoomsFilter {
        PublicRoomsFilter(genericSearchTerm: term, roomTypes: ["m.space"])
    }

    var json: JSONValue {
        var object: [String: JSONValue] = [:]
        if let genericSearchTerm { object["generic_search_term"] = .string(genericSearchTerm) }
        if let roomTypes { object["room_types"] = .array(roomTypes.map { $0.map(JSONValue.string) ?? .null }) }
        return .object(object)
    }
}

/// Страница каталога.
public struct PublicRoomsPage: Sendable, Equatable {
    public let rooms: [PublicRoom]
    public let nextBatch: String?
    public let prevBatch: String?
    public let totalRoomCountEstimate: Int?

    init(json: JSONValue) throws(MatrixError) {
        guard let chunk = json["chunk"]?.array else { throw MatrixError(.decoding("/publicRooms: нет chunk")) }
        rooms = chunk.compactMap(PublicRoom.init(json:))
        nextBatch = json["next_batch"]?.string
        prevBatch = json["prev_batch"]?.string
        totalRoomCountEstimate = json["total_room_count_estimate"]?.int
    }
}

/// Связь «пространство → дочерняя комната» (`m.space.child`), в иерархии приходит как `children_state`.
public struct SpaceChild: Sendable, Equatable {
    /// `state_key` — id дочерней комнаты.
    public let roomID: String
    public let via: [String]
    public let suggested: Bool
    /// Ключ ручной сортировки (строка из символов 0x20–0x7E, до 50 символов).
    public let order: String?
    public let sender: String?
    public let originServerTS: Int?

    init?(json: JSONValue) {
        guard json["type"]?.string == "m.space.child", let roomID = json["state_key"]?.string else { return nil }
        self.roomID = roomID
        let content = json["content"]
        via = (content?["via"]?.array ?? []).compactMap(\.string)
        suggested = content?["suggested"]?.bool ?? false
        order = content?["order"]?.string
        sender = json["sender"]?.string
        originServerTS = json["origin_server_ts"]?.int
    }
}

/// Комната в ответе /hierarchy: запись каталога плюс связи с детьми.
public struct SpaceHierarchyRoom: Sendable, Equatable {
    public let room: PublicRoom
    public let childrenState: [SpaceChild]
}

public struct SpaceHierarchyPage: Sendable, Equatable {
    /// Первая — сама запрошенная комната.
    public let rooms: [SpaceHierarchyRoom]
    public let nextBatch: String?

    init(json: JSONValue) throws(MatrixError) {
        guard let rooms = json["rooms"]?.array else { throw MatrixError(.decoding("/hierarchy: нет rooms")) }
        self.rooms = rooms.compactMap { item in
            PublicRoom(json: item).map {
                SpaceHierarchyRoom(room: $0,
                                   childrenState: (item["children_state"]?.array ?? []).compactMap(SpaceChild.init(json:)))
            }
        }
        nextBatch = json["next_batch"]?.string
    }
}

public extension MatrixClient {
    // MARK: Каталог

    /// POST /v3/publicRooms. `server` — чей каталог смотреть (по умолчанию домашний).
    func publicRooms(server: String? = nil, limit: Int? = nil, since: String? = nil,
                     filter: PublicRoomsFilter? = nil,
                     includeAllNetworks: Bool = false) async throws(MatrixError) -> PublicRoomsPage {
        var body: [String: JSONValue] = [:]
        if let limit { body["limit"] = .int(limit) }
        if let since { body["since"] = .string(since) }
        if let filter { body["filter"] = filter.json }
        if includeAllNetworks { body["include_all_networks"] = .bool(true) }
        let query = server.map { ["server": $0] } ?? [:]
        let json: JSONValue = try await request(.post, "publicRooms", query: query, body: .object(body))
        return try PublicRoomsPage(json: json)
    }

    /// Каталог сообществ Нютага: только `m.space`.
    func publicCommunities(server: String? = nil, search: String? = nil, limit: Int? = nil,
                           since: String? = nil) async throws(MatrixError) -> PublicRoomsPage {
        try await publicRooms(server: server, limit: limit, since: since, filter: .communities(searching: search))
    }

    /// Видимость комнаты в каталоге: `public` или `private`. Читать можно без токена.
    func roomVisibility(roomID: String) async throws(MatrixError) -> String {
        let json: JSONValue = try await request(.get, "directory/list/room/\(roomID)", authenticated: false)
        guard let visibility = json["visibility"]?.string else {
            throw MatrixError(.decoding("directory/list: нет visibility"))
        }
        return visibility
    }

    func setRoomVisibility(roomID: String, public isPublic: Bool) async throws(MatrixError) {
        let _: EmptyResponse = try await request(.put, "directory/list/room/\(roomID)",
                                                 body: ["visibility": isPublic ? "public" : "private"])
    }

    /// GET /v3/directory/room/{alias}: id комнаты и серверы, через которые в неё входить.
    func resolveAlias(_ alias: String) async throws(MatrixError) -> (roomID: String, servers: [String]) {
        let json: JSONValue = try await request(.get, "directory/room/\(alias)", authenticated: false)
        guard let roomID = json["room_id"]?.string else { throw MatrixError(.decoding("directory/room: нет room_id")) }
        return (roomID, (json["servers"]?.array ?? []).compactMap(\.string))
    }

    // MARK: Пространства

    /// GET /v1/rooms/{id}/hierarchy.
    func roomHierarchy(roomID: String, from: String? = nil, limit: Int? = nil, maxDepth: Int? = nil,
                       suggestedOnly: Bool = false) async throws(MatrixError) -> SpaceHierarchyPage {
        var query: [String: String] = [:]
        if let from { query["from"] = from }
        if let limit { query["limit"] = String(limit) }
        if let maxDepth { query["max_depth"] = String(maxDepth) }
        if suggestedOnly { query["suggested_only"] = "true" }
        let json: JSONValue = try await request(.get, "rooms/\(roomID)/hierarchy", version: "v1", query: query)
        return try SpaceHierarchyPage(json: json)
    }

    /// Добавить комнату в пространство: `m.space.child` в пространстве, `via` обязателен.
    @discardableResult
    func addSpaceChild(spaceID: String, childID: String, via: [String], suggested: Bool = false,
                       order: String? = nil) async throws(MatrixError) -> String {
        var content: [String: JSONValue] = ["via": .array(via.map(JSONValue.string))]
        if suggested { content["suggested"] = .bool(true) }
        if let order { content["order"] = .string(order) }
        return try await setState(roomID: spaceID, type: "m.space.child", stateKey: childID, content: .object(content))
    }

    /// Убрать комнату из пространства: по спеке связь снимается пустым содержимым.
    @discardableResult
    func removeSpaceChild(spaceID: String, childID: String) async throws(MatrixError) -> String {
        try await setState(roomID: spaceID, type: "m.space.child", stateKey: childID, content: [:])
    }

    /// Обратная ссылка `m.space.parent` в дочерней комнате.
    @discardableResult
    func setSpaceParent(roomID: String, spaceID: String, via: [String],
                        canonical: Bool = false) async throws(MatrixError) -> String {
        var content: [String: JSONValue] = ["via": .array(via.map(JSONValue.string))]
        if canonical { content["canonical"] = .bool(true) }
        return try await setState(roomID: roomID, type: "m.space.parent", stateKey: spaceID, content: .object(content))
    }

    @discardableResult
    func removeSpaceParent(roomID: String, spaceID: String) async throws(MatrixError) -> String {
        try await setState(roomID: roomID, type: "m.space.parent", stateKey: spaceID, content: [:])
    }

    // MARK: Knock

    /// POST /v3/knock/{roomIdOrAlias}: постучаться в комнату с правилом входа `knock`. Возвращает id комнаты.
    /// Каждый сервер из `via` уходит и как `via`, и как исторический `server_name`.
    @discardableResult
    func knock(_ roomIDOrAlias: String, reason: String? = nil, via: [String] = []) async throws(MatrixError) -> String {
        let query: [String: [String]] = via.isEmpty ? [:] : ["via": via, "server_name": via]
        let body: JSONValue = reason.map { ["reason": .string($0)] } ?? [:]
        let json: JSONValue = try await request(.post, "knock/\(roomIDOrAlias)", repeatedQuery: query, body: body)
        guard let roomID = json["room_id"]?.string else { throw MatrixError(.decoding("knock: нет room_id")) }
        return roomID
    }
}
