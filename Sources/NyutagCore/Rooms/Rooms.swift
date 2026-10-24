// Нютаг. Действия с комнатами: история (/messages), отправка и удаление событий, состояние, вход и выход,
// отметки прочтения и набор текста.

import Foundation

/// Страница истории из `/messages`.
public struct MessagesPage: Sendable {
    /// В порядке запроса: для `.backward` от новых к старым.
    public let events: [Event]
    public let state: [Event]
    public let start: String
    /// Маркер следующей страницы; `nil` — история кончилась.
    public let end: String?

    init(json: JSONValue, roomID: String) throws(MatrixError) {
        guard let start = json["start"]?.string else { throw MatrixError(.decoding("/messages: нет start")) }
        self.start = start
        end = json["end"]?.string
        func parse(_ key: String) -> [Event] {
            (json[key]?.array ?? []).compactMap(Event.init(json:)).map { event in
                var event = event
                if event.roomID == nil { event.roomID = roomID }
                return event
            }
        }
        events = parse("chunk")
        state = parse("state")
    }
}

public enum Direction: String, Sendable {
    case backward = "b", forward = "f"
}

/// Источник идентификаторов транзакций: уникальны в пределах устройства, повтор того же id сервер не дублирует.
public enum TransactionID {
    public static func make() -> String {
        "ny" + String(Int(Date().timeIntervalSince1970 * 1000)) + "." + UUID().uuidString.prefix(8).lowercased()
    }
}

public extension MatrixClient {
    // MARK: История

    func messages(roomID: String, from: String?, direction: Direction = .backward, limit: Int = 50,
                  filter: JSONValue? = nil) async throws(MatrixError) -> MessagesPage {
        var query = ["dir": direction.rawValue, "limit": String(limit)]
        if let from { query["from"] = from }
        if let filter { query["filter"] = filter.canonicalJSON() }
        let json: JSONValue = try await request(.get, "rooms/\(roomID)/messages", query: query)
        return try MessagesPage(json: json, roomID: roomID)
    }

    func event(roomID: String, eventID: String) async throws(MatrixError) -> Event {
        let json: JSONValue = try await request(.get, "rooms/\(roomID)/event/\(eventID)")
        guard let event = Event(json: json) else { throw MatrixError(.decoding("событие \(eventID)")) }
        return event
    }

    /// Окрестность события (переход к ответу или закреплённому сообщению).
    func context(roomID: String, eventID: String, limit: Int = 20) async throws(MatrixError) -> JSONValue {
        try await request(.get, "rooms/\(roomID)/context/\(eventID)", query: ["limit": String(limit)])
    }

    // MARK: Отправка

    /// Отправка события таймлайна. Возвращает `event_id`.
    @discardableResult
    func send(roomID: String, type: String, content: JSONValue,
              transactionID: String = TransactionID.make()) async throws(MatrixError) -> String {
        let json: JSONValue = try await request(.put, "rooms/\(roomID)/send/\(type)/\(transactionID)", body: content)
        guard let eventID = json["event_id"]?.string else { throw MatrixError(.decoding("send: нет event_id")) }
        return eventID
    }

    @discardableResult
    func sendText(roomID: String, _ body: String) async throws(MatrixError) -> String {
        try await send(roomID: roomID, type: EventType.message,
                       content: ["msgtype": "m.text", "body": .string(body)])
    }

    @discardableResult
    func redact(roomID: String, eventID: String, reason: String? = nil,
                transactionID: String = TransactionID.make()) async throws(MatrixError) -> String {
        var body: [String: JSONValue] = [:]
        if let reason { body["reason"] = .string(reason) }
        let json: JSONValue = try await request(.put, "rooms/\(roomID)/redact/\(eventID)/\(transactionID)",
                                                body: .object(body))
        guard let id = json["event_id"]?.string else { throw MatrixError(.decoding("redact: нет event_id")) }
        return id
    }

    @discardableResult
    func setState(roomID: String, type: String, stateKey: String = "",
                  content: JSONValue) async throws(MatrixError) -> String {
        let json: JSONValue = try await request(.put, "rooms/\(roomID)/state/\(type)/\(stateKey)", body: content)
        guard let id = json["event_id"]?.string else { throw MatrixError(.decoding("state: нет event_id")) }
        return id
    }

    func state(roomID: String, type: String, stateKey: String = "") async throws(MatrixError) -> JSONValue {
        try await request(.get, "rooms/\(roomID)/state/\(type)/\(stateKey)")
    }

    /// Создатели комнаты: с версии 12 у них неограниченные права, а в `power_levels` их нет — это автор
    /// `m.room.create` и `additional_creators`. В комнатах до 12-й права создателя записаны в `power_levels`: пусто.
    func creators(roomID: String) async throws(MatrixError) -> Set<String> {
        let event: JSONValue = try await request(.get, "rooms/\(roomID)/state/m.room.create/", query: ["format": "event"])
        let version = event["content"]?["room_version"]?.string ?? "1"
        if let number = Int(version), number < 12 { return [] }
        let extra = (event["content"]?["additional_creators"]?.array ?? []).compactMap(\.string)
        return Set(([event["sender"]?.string].compactMap(\.self)) + extra)
    }

    // MARK: Членство

    struct CreateRoom: Sendable {
        public var name: String?
        public var topic: String?
        public var invite: [String] = []
        public var isDirect = false
        public var preset = "private_chat"
        public var encrypted = true
        public var roomType: String?

        public init(name: String? = nil, topic: String? = nil, invite: [String] = [], isDirect: Bool = false,
                    preset: String = "private_chat", encrypted: Bool = true, roomType: String? = nil) {
            self.name = name
            self.topic = topic
            self.invite = invite
            self.isDirect = isDirect
            self.preset = preset
            self.encrypted = encrypted
            self.roomType = roomType
        }

        var json: JSONValue {
            var body: [String: JSONValue] = ["preset": .string(preset), "is_direct": .bool(isDirect)]
            if let name { body["name"] = .string(name) }
            if let topic { body["topic"] = .string(topic) }
            if !invite.isEmpty { body["invite"] = .array(invite.map(JSONValue.string)) }
            if let roomType { body["creation_content"] = ["type": .string(roomType)] }
            if encrypted {
                body["initial_state"] = [[
                    "type": .string(EventType.encryption), "state_key": "",
                    "content": ["algorithm": "m.megolm.v1.aes-sha2"],
                ]]
            }
            return .object(body)
        }
    }

    func createRoom(_ options: CreateRoom) async throws(MatrixError) -> String {
        let json: JSONValue = try await request(.post, "createRoom", body: options.json)
        guard let roomID = json["room_id"]?.string else { throw MatrixError(.decoding("createRoom: нет room_id")) }
        return roomID
    }

    /// Вход по id или алиасу. `via` — серверы, через которые искать комнату.
    @discardableResult
    func join(_ roomIDOrAlias: String, via: [String] = []) async throws(MatrixError) -> String {
        let query = via.isEmpty ? [:] : ["server_name": via.joined(separator: ",")]
        let json: JSONValue = try await request(.post, "join/\(roomIDOrAlias)", query: query, body: [:])
        guard let roomID = json["room_id"]?.string else { throw MatrixError(.decoding("join: нет room_id")) }
        return roomID
    }

    func leave(roomID: String, reason: String? = nil) async throws(MatrixError) {
        let body: JSONValue = reason.map { ["reason": .string($0)] } ?? [:]
        let _: EmptyResponse = try await request(.post, "rooms/\(roomID)/leave", body: body)
    }

    func forget(roomID: String) async throws(MatrixError) {
        let _: EmptyResponse = try await request(.post, "rooms/\(roomID)/forget", body: [:])
    }

    /// Комнаты, где мы сейчас `join`, по мнению сервера.
    func joinedRooms() async throws(MatrixError) -> Set<String> {
        let json: JSONValue = try await request(.get, "joined_rooms")
        return Set((json["joined_rooms"]?.array ?? []).compactMap(\.string))
    }

    func invite(roomID: String, userID: String, reason: String? = nil) async throws(MatrixError) {
        var body: [String: JSONValue] = ["user_id": .string(userID)]
        if let reason { body["reason"] = .string(reason) }
        let _: EmptyResponse = try await request(.post, "rooms/\(roomID)/invite", body: .object(body))
    }

    func kick(roomID: String, userID: String, reason: String? = nil) async throws(MatrixError) {
        var body: [String: JSONValue] = ["user_id": .string(userID)]
        if let reason { body["reason"] = .string(reason) }
        let _: EmptyResponse = try await request(.post, "rooms/\(roomID)/kick", body: .object(body))
    }

    func ban(roomID: String, userID: String, reason: String? = nil) async throws(MatrixError) {
        var body: [String: JSONValue] = ["user_id": .string(userID)]
        if let reason { body["reason"] = .string(reason) }
        let _: EmptyResponse = try await request(.post, "rooms/\(roomID)/ban", body: .object(body))
    }

    func unban(roomID: String, userID: String) async throws(MatrixError) {
        let _: EmptyResponse = try await request(.post, "rooms/\(roomID)/unban", body: ["user_id": .string(userID)])
    }

    /// Полный список участников (для отправки ключей Megolm нужны все устройства joined и invited).
    func members(roomID: String, notMembership: String? = "leave") async throws(MatrixError) -> [Event] {
        let query = notMembership.map { ["not_membership": $0] } ?? [:]
        let json: JSONValue = try await request(.get, "rooms/\(roomID)/members", query: query)
        return (json["chunk"]?.array ?? []).compactMap(Event.init(json:))
    }

    // MARK: Прочтение и набор

    /// Публичная и приватная отметка прочтения плюс маркер полностью прочитанного одним запросом.
    func setReadMarkers(roomID: String, fullyRead: String? = nil, read: String? = nil,
                        readPrivate: String? = nil) async throws(MatrixError) {
        var body: [String: JSONValue] = [:]
        if let fullyRead { body["m.fully_read"] = .string(fullyRead) }
        if let read { body["m.read"] = .string(read) }
        if let readPrivate { body["m.read.private"] = .string(readPrivate) }
        let _: EmptyResponse = try await request(.post, "rooms/\(roomID)/read_markers", body: .object(body))
    }

    func setTyping(roomID: String, userID: String, typing: Bool, timeout: Duration = .seconds(20)) async throws(MatrixError) {
        var body: [String: JSONValue] = ["typing": .bool(typing)]
        if typing { body["timeout"] = .int(Int(timeout.components.seconds * 1000)) }
        let _: EmptyResponse = try await request(.put, "rooms/\(roomID)/typing/\(userID)", body: .object(body))
    }

    // MARK: Данные учётки

    func setAccountData(userID: String, type: String, roomID: String? = nil,
                        content: JSONValue) async throws(MatrixError) {
        let path = roomID.map { "user/\(userID)/rooms/\($0)/account_data/\(type)" } ?? "user/\(userID)/account_data/\(type)"
        let _: EmptyResponse = try await request(.put, path, body: content)
    }

    func accountData(userID: String, type: String, roomID: String? = nil) async throws(MatrixError) -> JSONValue {
        let path = roomID.map { "user/\(userID)/rooms/\($0)/account_data/\(type)" } ?? "user/\(userID)/account_data/\(type)"
        return try await request(.get, path)
    }
}

public extension SyncEngine {
    /// Выйти из комнаты; с `forget` ещё и забыть её на сервере и стереть локально.
    func leave(roomID: String, forget: Bool = false) async throws(MatrixError) {
        try await client.leave(roomID: roomID)
        guard forget else { return }
        try await client.forget(roomID: roomID)
        do { try await store.deleteRoom(roomID) } catch { throw MatrixError(.decoding("хранилище: \(error)")) }
    }

    /// Комнату, которую на другом устройстве покинули и забыли, `/sync` больше не присылает вовсе, и здесь она
    /// навсегда осталась бы `join`. Сверяемся со списком сервера; возвращает комнаты, помеченные покинутыми.
    @discardableResult
    func dropForgotten() async throws(MatrixError) -> [String] {
        // Снимок до запроса: комната, в которую вошли, пока он шёл, в снимок не попадёт и не пострадает.
        let local: [RoomRecord]
        do { local = try await store.rooms(membership: .join) } catch { throw MatrixError(.decoding("хранилище: \(error)")) }
        let joined = try await client.joinedRooms()
        let gone = local.filter { !joined.contains($0.id) }
        do {
            for var record in gone {
                record.membership = .leave
                try await store.upsert(record)
            }
        } catch { throw MatrixError(.decoding("хранилище: \(error)")) }
        return gone.map(\.id)
    }

    /// Докачивает страницу истории назад от сохранённого `prev_batch` комнаты и кладёт её в хранилище.
    /// Возвращает число новых событий; 0 при `hasMore == false` значит, что начало комнаты достигнуто.
    @discardableResult
    func backfill(roomID: String, limit: Int = 50) async throws(MatrixError) -> (added: Int, hasMore: Bool) {
        let record: RoomRecord?
        do { record = try await store.room(roomID) } catch { throw MatrixError(.decoding("хранилище: \(error)")) }
        guard var record, let from = record.prevBatch else { return (0, false) }
        let page = try await client.messages(roomID: roomID, from: from, direction: .backward, limit: limit)
        do {
            let added = try await store.prepend(page.events, roomID: roomID)
            // Участники из ленивой подгрузки: только если о них ещё ничего не знаем, свежий sync важнее старой страницы.
            for event in page.state where try await store.state(roomID, type: event.type, stateKey: event.stateKey ?? "") == nil {
                try await store.setState(event)
            }
            record.prevBatch = page.end
            try await store.upsert(record)
            return (added, page.end != nil && !page.events.isEmpty)
        } catch {
            throw MatrixError(.decoding("хранилище: \(error)"))
        }
    }
}
