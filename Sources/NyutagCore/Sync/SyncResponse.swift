// Нютаг. Разбор ответа `/sync` (клиент-серверное API v3) в структуры движка. Разбираем из дерева JSON, а не
// через Codable: формат местами разнороден, а нам нужны только известные поля.

import Foundation

public struct SyncResponse: Sendable {
    public let nextBatch: String
    public let joined: [String: JoinedRoom]
    public let invited: [String: InvitedRoom]
    public let left: [String: LeftRoom]
    public let knocked: [String: KnockedRoom]
    public let accountData: [Event]
    public let presence: [Event]
    public let toDevice: [Event]
    public let deviceListsChanged: [String]
    public let deviceListsLeft: [String]
    public let oneTimeKeysCount: [String: Int]
    public let unusedFallbackKeys: [String]?

    public struct Timeline: Sendable {
        public let events: [Event]
        public let limited: Bool
        public let prevBatch: String?
    }

    public struct UnreadNotifications: Sendable, Equatable {
        public let highlight: Int
        public let notification: Int
    }

    public struct JoinedRoom: Sendable {
        public let state: [Event]
        public let timeline: Timeline
        public let ephemeral: [Event]
        public let accountData: [Event]
        public let unread: UnreadNotifications
        public let summary: Summary

        public struct Summary: Sendable, Equatable {
            public let heroes: [String]?
            public let joinedCount: Int?
            public let invitedCount: Int?
        }
    }

    public struct InvitedRoom: Sendable {
        public let inviteState: [Event]
    }

    public struct LeftRoom: Sendable {
        public let state: [Event]
        public let timeline: Timeline
        public let accountData: [Event]
    }

    public struct KnockedRoom: Sendable {
        public let knockState: [Event]
    }

    public init(json: JSONValue) throws(MatrixError) {
        guard let nextBatch = json["next_batch"]?.string else {
            throw MatrixError(.decoding("sync: нет next_batch"))
        }
        self.nextBatch = nextBatch

        var joined: [String: JoinedRoom] = [:]
        for (roomID, room) in json["rooms", "join"]?.object ?? [:] {
            joined[roomID] = JoinedRoom(roomID: roomID, json: room)
        }
        self.joined = joined

        var invited: [String: InvitedRoom] = [:]
        for (roomID, room) in json["rooms", "invite"]?.object ?? [:] {
            invited[roomID] = InvitedRoom(inviteState: Self.events(room["invite_state", "events"], roomID: roomID))
        }
        self.invited = invited

        var left: [String: LeftRoom] = [:]
        for (roomID, room) in json["rooms", "leave"]?.object ?? [:] {
            left[roomID] = LeftRoom(state: Self.events(room["state", "events"], roomID: roomID),
                                    timeline: Timeline(json: room["timeline"], roomID: roomID),
                                    accountData: Self.events(room["account_data", "events"], roomID: roomID))
        }
        self.left = left

        var knocked: [String: KnockedRoom] = [:]
        for (roomID, room) in json["rooms", "knock"]?.object ?? [:] {
            knocked[roomID] = KnockedRoom(knockState: Self.events(room["knock_state", "events"], roomID: roomID))
        }
        self.knocked = knocked

        accountData = Self.events(json["account_data", "events"])
        presence = Self.events(json["presence", "events"])
        toDevice = Self.events(json["to_device", "events"])
        deviceListsChanged = json["device_lists", "changed"]?.array?.compactMap(\.string) ?? []
        deviceListsLeft = json["device_lists", "left"]?.array?.compactMap(\.string) ?? []
        oneTimeKeysCount = (json["device_one_time_keys_count"]?.object ?? [:]).compactMapValues(\.int)
        unusedFallbackKeys = (json["device_unused_fallback_key_types"] ?? json["org.matrix.msc2732.device_unused_fallback_key_types"])?
            .array?.compactMap(\.string)
    }

    static func events(_ json: JSONValue?, roomID: String? = nil) -> [Event] {
        (json?.array ?? []).compactMap { item in
            guard var event = Event(json: item) else { return nil }
            if event.roomID == nil { event.roomID = roomID }
            return event
        }
    }

    public var isEmpty: Bool {
        joined.isEmpty && invited.isEmpty && left.isEmpty && knocked.isEmpty && accountData.isEmpty
            && presence.isEmpty && toDevice.isEmpty && deviceListsChanged.isEmpty
    }
}

extension SyncResponse.Timeline {
    init(json: JSONValue?, roomID: String) {
        events = SyncResponse.events(json?["events"], roomID: roomID)
        limited = json?["limited"]?.bool ?? false
        prevBatch = json?["prev_batch"]?.string
    }
}

extension SyncResponse.JoinedRoom {
    init(roomID: String, json: JSONValue) {
        state = SyncResponse.events(json["state", "events"], roomID: roomID)
        timeline = SyncResponse.Timeline(json: json["timeline"], roomID: roomID)
        ephemeral = SyncResponse.events(json["ephemeral", "events"], roomID: roomID)
        accountData = SyncResponse.events(json["account_data", "events"], roomID: roomID)
        unread = SyncResponse.UnreadNotifications(highlight: json["unread_notifications", "highlight_count"]?.int ?? 0,
                                                  notification: json["unread_notifications", "notification_count"]?.int ?? 0)
        summary = Summary(heroes: json["summary", "m.heroes"]?.array?.compactMap(\.string),
                          joinedCount: json["summary", "m.joined_member_count"]?.int,
                          invitedCount: json["summary", "m.invited_member_count"]?.int)
    }
}

/// Фильтр /sync: ограничиваем хвост таймлайна и отключаем то, что не показываем.
public enum SyncFilter {
    /// Первый sync: короткий таймлайн, чтобы стартовать быстро; историю докачивает `/messages`.
    public static func initial(timelineLimit: Int = 20) -> JSONValue {
        [
            "room": [
                "timeline": ["limit": .int(timelineLimit), "lazy_load_members": true],
                "state": ["lazy_load_members": true],
                "ephemeral": ["types": ["m.receipt", "m.typing"]],
            ],
            "presence": ["types": []],
        ]
    }

    public static func incremental(timelineLimit: Int = 50) -> JSONValue {
        [
            "room": [
                "timeline": ["limit": .int(timelineLimit), "lazy_load_members": true],
                "state": ["lazy_load_members": true],
                "ephemeral": ["types": ["m.receipt", "m.typing"]],
            ],
            "presence": ["types": []],
        ]
    }
}

public extension MatrixClient {
    /// Один вызов `/sync`. `timeout` — long-poll на сервере; сетевой таймаут берётся с запасом.
    func sync(since: String?, filter: JSONValue?, timeout: Duration, setPresence: String = "online") async throws(MatrixError) -> SyncResponse {
        var query: [String: String] = ["timeout": String(timeout.components.seconds * 1000), "set_presence": setPresence]
        if let since { query["since"] = since }
        if let filter { query["filter"] = filter.canonicalJSON() }
        let json: JSONValue = try await request(.get, "sync", query: query, timeout: timeout + .seconds(10))
        return try SyncResponse(json: json)
    }
}
