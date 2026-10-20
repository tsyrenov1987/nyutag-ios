// Нютаг. Событие Matrix в том виде, в каком его отдаёт /sync: тип, отправитель, содержимое как дерево JSON.

import Foundation

public struct Event: Sendable, Equatable, Hashable {
    public let eventID: String?
    public let type: String
    public let sender: String?
    public let originServerTS: Int?
    public let stateKey: String?
    public let content: JSONValue
    public let unsigned: JSONValue?
    /// Заполняется движком при разборе /sync; в самом событии комнаты поля нет.
    public var roomID: String?

    public init(eventID: String? = nil, type: String, sender: String? = nil, originServerTS: Int? = nil,
                stateKey: String? = nil, content: JSONValue, unsigned: JSONValue? = nil, roomID: String? = nil) {
        self.eventID = eventID
        self.type = type
        self.sender = sender
        self.originServerTS = originServerTS
        self.stateKey = stateKey
        self.content = content
        self.unsigned = unsigned
        self.roomID = roomID
    }

    public init?(json: JSONValue) {
        guard let type = json["type"]?.string else { return nil }
        self.init(eventID: json["event_id"]?.string,
                  type: type,
                  sender: json["sender"]?.string,
                  originServerTS: json["origin_server_ts"]?.int,
                  stateKey: json["state_key"]?.string,
                  content: json["content"] ?? .object([:]),
                  unsigned: json["unsigned"],
                  roomID: json["room_id"]?.string)
    }

    public var isState: Bool { stateKey != nil }

    public var json: JSONValue {
        var object: [String: JSONValue] = ["type": .string(type), "content": content]
        if let eventID { object["event_id"] = .string(eventID) }
        if let sender { object["sender"] = .string(sender) }
        if let originServerTS { object["origin_server_ts"] = .int(originServerTS) }
        if let stateKey { object["state_key"] = .string(stateKey) }
        if let unsigned { object["unsigned"] = unsigned }
        if let roomID { object["room_id"] = .string(roomID) }
        return .object(object)
    }

    /// Идентификатор транзакции нашего собственного эха (сервер возвращает его в `unsigned.transaction_id`).
    public var transactionID: String? { unsigned?["transaction_id"]?.string }

    /// Удалено ли событие (сервер оставляет `unsigned.redacted_because`).
    public var isRedacted: Bool { unsigned?["redacted_because"] != nil }
}

public enum EventType {
    public static let message = "m.room.message"
    public static let encrypted = "m.room.encrypted"
    public static let member = "m.room.member"
    public static let name = "m.room.name"
    public static let topic = "m.room.topic"
    public static let avatar = "m.room.avatar"
    public static let create = "m.room.create"
    public static let canonicalAlias = "m.room.canonical_alias"
    public static let encryption = "m.room.encryption"
    public static let redaction = "m.room.redaction"
    public static let reaction = "m.reaction"
    public static let powerLevels = "m.room.power_levels"
    public static let joinRules = "m.room.join_rules"
    public static let tombstone = "m.room.tombstone"
    public static let roomKey = "m.room_key"
    public static let forwardedRoomKey = "m.forwarded_room_key"
    public static let roomKeyRequest = "m.room_key_request"
    public static let receipt = "m.receipt"
    public static let typing = "m.typing"
    public static let presence = "m.presence"
    public static let direct = "m.direct"
    public static let pushRules = "m.push_rules"
    public static let fullyRead = "m.fully_read"

    // Свои типы Нютага; форматы общие с Android-клиентом.
    public static let chatLayout = "chat.nyutag.chat_layout"
    public static let savedMessages = "chat.nyutag.saved_messages"
    public static let autodelete = "chat.nyutag.autodelete"
    public static let call = "chat.nyutag.call"
}
