// Нютаг. Хранилище сеанса: комнаты, события, состояние, account data, маркер /sync. Одна база SQLite на аккаунт.

import Foundation

public struct RoomRecord: Sendable, Equatable, Identifiable {
    public enum Membership: String, Sendable { case join, invite, leave, knock, ban }

    public var id: String
    public var membership: Membership
    public var name: String?
    public var topic: String?
    public var avatarURL: String?
    public var canonicalAlias: String?
    public var isEncrypted: Bool
    public var isDirect: Bool
    public var isSpace: Bool
    public var joinedCount: Int
    public var invitedCount: Int
    public var heroes: [String]
    public var highlightCount: Int
    public var notificationCount: Int
    public var latestTS: Int
    public var prevBatch: String?

    public init(id: String, membership: Membership) {
        self.id = id
        self.membership = membership
        name = nil
        topic = nil
        avatarURL = nil
        canonicalAlias = nil
        isEncrypted = false
        isDirect = false
        isSpace = false
        joinedCount = 0
        invitedCount = 0
        heroes = []
        highlightCount = 0
        notificationCount = 0
        latestTS = 0
        prevBatch = nil
    }
}

/// Хранилище на SQLite. Актор: один писатель, читатели ждут своей очереди.
public actor Store {
    public static let schemaVersion = 1

    let db: SQLite
    /// Сквозной порядок событий таймлайна: события из /sync идут в хронологии получения, события из `/messages` в прошлое.
    private var nextOrdering: Int64 = 0

    public init(path: String) throws {
        db = try SQLite(path: path)
        try Self.migrate(db)
        nextOrdering = (try db.scalar("SELECT COALESCE(MAX(ordering), 0) FROM events")?.int.map(Int64.init) ?? 0) + 1
    }

    public static func inMemory() throws -> Store {
        try Store(path: ":memory:")
    }

    private static func migrate(_ db: SQLite) throws {
        let version = try db.scalar("PRAGMA user_version")?.int ?? 0
        if version < 1 {
            try db.exec("""
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE IF NOT EXISTS rooms (
                room_id TEXT PRIMARY KEY,
                membership TEXT NOT NULL,
                name TEXT, topic TEXT, avatar_url TEXT, canonical_alias TEXT,
                is_encrypted INTEGER NOT NULL DEFAULT 0,
                is_direct INTEGER NOT NULL DEFAULT 0,
                is_space INTEGER NOT NULL DEFAULT 0,
                joined_count INTEGER NOT NULL DEFAULT 0,
                invited_count INTEGER NOT NULL DEFAULT 0,
                heroes TEXT NOT NULL DEFAULT '[]',
                highlight_count INTEGER NOT NULL DEFAULT 0,
                notification_count INTEGER NOT NULL DEFAULT 0,
                latest_ts INTEGER NOT NULL DEFAULT 0,
                prev_batch TEXT
            );
            CREATE TABLE IF NOT EXISTS events (
                event_id TEXT PRIMARY KEY,
                room_id TEXT NOT NULL,
                type TEXT NOT NULL,
                sender TEXT,
                ts INTEGER NOT NULL DEFAULT 0,
                state_key TEXT,
                content TEXT NOT NULL,
                unsigned TEXT,
                ordering INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS events_room_ordering ON events(room_id, ordering);
            CREATE TABLE IF NOT EXISTS state (
                room_id TEXT NOT NULL,
                type TEXT NOT NULL,
                state_key TEXT NOT NULL,
                event_id TEXT,
                sender TEXT,
                content TEXT NOT NULL,
                PRIMARY KEY (room_id, type, state_key)
            );
            CREATE TABLE IF NOT EXISTS account_data (
                room_id TEXT NOT NULL DEFAULT '',
                type TEXT NOT NULL,
                content TEXT NOT NULL,
                PRIMARY KEY (room_id, type)
            );
            CREATE TABLE IF NOT EXISTS receipts (
                room_id TEXT NOT NULL,
                user_id TEXT NOT NULL,
                event_id TEXT NOT NULL,
                ts INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (room_id, user_id)
            );
            PRAGMA user_version = 1;
            """)
        }
    }

    // MARK: Meta

    public func meta(_ key: String) throws -> String? {
        try db.scalar("SELECT value FROM meta WHERE key = ?", .text(key))?.string
    }

    public func setMeta(_ key: String, _ value: String?) throws {
        if let value {
            try db.run("INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                       .text(key), .text(value))
        } else {
            try db.run("DELETE FROM meta WHERE key = ?", .text(key))
        }
    }

    public var syncToken: String? {
        get throws { try meta("sync_token") }
    }

    // MARK: Комнаты

    public func room(_ roomID: String) throws -> RoomRecord? {
        try db.query("SELECT * FROM rooms WHERE room_id = ?", .text(roomID), row: Self.roomRecord).first
    }

    public func rooms(membership: RoomRecord.Membership? = nil) throws -> [RoomRecord] {
        if let membership {
            return try db.query("SELECT * FROM rooms WHERE membership = ? ORDER BY latest_ts DESC",
                                .text(membership.rawValue), row: Self.roomRecord)
        }
        return try db.query("SELECT * FROM rooms ORDER BY latest_ts DESC", row: Self.roomRecord)
    }

    public func upsert(_ room: RoomRecord) throws {
        try db.run("""
        INSERT INTO rooms(room_id, membership, name, topic, avatar_url, canonical_alias, is_encrypted, is_direct, is_space,
                          joined_count, invited_count, heroes, highlight_count, notification_count, latest_ts, prev_batch)
        VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(room_id) DO UPDATE SET
            membership = excluded.membership, name = excluded.name, topic = excluded.topic, avatar_url = excluded.avatar_url,
            canonical_alias = excluded.canonical_alias, is_encrypted = excluded.is_encrypted, is_direct = excluded.is_direct,
            is_space = excluded.is_space, joined_count = excluded.joined_count, invited_count = excluded.invited_count,
            heroes = excluded.heroes, highlight_count = excluded.highlight_count, notification_count = excluded.notification_count,
            latest_ts = excluded.latest_ts, prev_batch = excluded.prev_batch
        """, [
            .text(room.id), .text(room.membership.rawValue), .init(room.name), .init(room.topic), .init(room.avatarURL),
            .init(room.canonicalAlias), .init(room.isEncrypted), .init(room.isDirect), .init(room.isSpace),
            .init(room.joinedCount), .init(room.invitedCount), .init(json: .array(room.heroes.map(JSONValue.string))),
            .init(room.highlightCount), .init(room.notificationCount), .init(room.latestTS), .init(room.prevBatch),
        ])
    }

    private static func roomRecord(_ row: SQLite.Row) -> RoomRecord {
        var room = RoomRecord(id: row.string(0) ?? "", membership: RoomRecord.Membership(rawValue: row.string(1) ?? "leave") ?? .leave)
        room.name = row.string(2)
        room.topic = row.string(3)
        room.avatarURL = row.string(4)
        room.canonicalAlias = row.string(5)
        room.isEncrypted = row.bool(6)
        room.isDirect = row.bool(7)
        room.isSpace = row.bool(8)
        room.joinedCount = row.int(9) ?? 0
        room.invitedCount = row.int(10) ?? 0
        room.heroes = row.value(11).json?.array?.compactMap(\.string) ?? []
        room.highlightCount = row.int(12) ?? 0
        room.notificationCount = row.int(13) ?? 0
        room.latestTS = row.int(14) ?? 0
        room.prevBatch = row.string(15)
        return room
    }

    // MARK: События

    /// Добавляет события таймлайна в порядке получения. Дубликаты (тот же event_id) пропускаются.
    public func append(_ events: [Event]) throws {
        for event in events {
            guard let eventID = event.eventID, let roomID = event.roomID else { continue }
            try db.run("""
            INSERT OR IGNORE INTO events(event_id, room_id, type, sender, ts, state_key, content, unsigned, ordering)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [
                .text(eventID), .text(roomID), .text(event.type), .init(event.sender), .init(event.originServerTS ?? 0),
                .init(event.stateKey), .init(json: event.content), .init(json: event.unsigned), .integer(nextOrdering),
            ])
            if db.changes > 0 { nextOrdering += 1 }
        }
    }

    /// Последние события комнаты, старые первыми.
    public func events(in roomID: String, limit: Int = 50, before ordering: Int64? = nil) throws -> [Event] {
        let rows: [Event]
        if let ordering {
            rows = try db.query("SELECT * FROM events WHERE room_id = ? AND ordering < ? ORDER BY ordering DESC LIMIT ?",
                                .text(roomID), .integer(ordering), .init(limit), row: Self.event)
        } else {
            rows = try db.query("SELECT * FROM events WHERE room_id = ? ORDER BY ordering DESC LIMIT ?",
                                .text(roomID), .init(limit), row: Self.event)
        }
        return rows.reversed()
    }

    public func event(_ eventID: String) throws -> Event? {
        try db.query("SELECT * FROM events WHERE event_id = ?", .text(eventID), row: Self.event).first
    }

    public func replace(_ event: Event) throws {
        guard let eventID = event.eventID else { return }
        try db.run("UPDATE events SET type = ?, content = ?, unsigned = ? WHERE event_id = ?",
                   .text(event.type), .init(json: event.content), .init(json: event.unsigned), .text(eventID))
    }

    public func eventCount(in roomID: String) throws -> Int {
        try db.scalar("SELECT COUNT(*) FROM events WHERE room_id = ?", .text(roomID))?.int ?? 0
    }

    private static func event(_ row: SQLite.Row) -> Event {
        Event(eventID: row.string(0), type: row.string(2) ?? "", sender: row.string(3), originServerTS: row.int(4),
              stateKey: row.string(5), content: row.value(6).json ?? .object([:]), unsigned: row.value(7).json,
              roomID: row.string(1))
    }

    // MARK: Состояние

    public func setState(_ event: Event) throws {
        guard let roomID = event.roomID, let stateKey = event.stateKey else { return }
        try db.run("""
        INSERT INTO state(room_id, type, state_key, event_id, sender, content) VALUES(?, ?, ?, ?, ?, ?)
        ON CONFLICT(room_id, type, state_key) DO UPDATE SET event_id = excluded.event_id, sender = excluded.sender, content = excluded.content
        """, [.text(roomID), .text(event.type), .text(stateKey), .init(event.eventID), .init(event.sender), .init(json: event.content)])
    }

    public func state(_ roomID: String, type: String, stateKey: String = "") throws -> JSONValue? {
        try db.scalar("SELECT content FROM state WHERE room_id = ? AND type = ? AND state_key = ?",
                      .text(roomID), .text(type), .text(stateKey))?.json
    }

    /// Все события состояния одного типа (например, участники).
    public func state(_ roomID: String, type: String) throws -> [(stateKey: String, sender: String?, content: JSONValue)] {
        try db.query("SELECT state_key, sender, content FROM state WHERE room_id = ? AND type = ?", .text(roomID), .text(type)) { row in
            (row.string(0) ?? "", row.string(1), row.value(2).json ?? .object([:]))
        }
    }

    // MARK: Account data

    public func setAccountData(_ type: String, roomID: String = "", content: JSONValue) throws {
        try db.run("INSERT INTO account_data(room_id, type, content) VALUES(?, ?, ?) ON CONFLICT(room_id, type) DO UPDATE SET content = excluded.content",
                   .text(roomID), .text(type), .init(json: content))
    }

    public func accountData(_ type: String, roomID: String = "") throws -> JSONValue? {
        try db.scalar("SELECT content FROM account_data WHERE room_id = ? AND type = ?", .text(roomID), .text(type))?.json
    }

    // MARK: Квитанции прочтения

    public func setReceipt(roomID: String, userID: String, eventID: String, ts: Int) throws {
        try db.run("INSERT INTO receipts(room_id, user_id, event_id, ts) VALUES(?, ?, ?, ?) ON CONFLICT(room_id, user_id) DO UPDATE SET event_id = excluded.event_id, ts = excluded.ts",
                   .text(roomID), .text(userID), .text(eventID), .init(ts))
    }

    public func receipt(roomID: String, userID: String) throws -> String? {
        try db.scalar("SELECT event_id FROM receipts WHERE room_id = ? AND user_id = ?", .text(roomID), .text(userID))?.string
    }

    // MARK: Транзакции

    public func transaction<T: Sendable>(_ body: @Sendable () throws -> T) throws -> T {
        try db.transaction(body)
    }

    /// Стереть всё (выход из аккаунта).
    public func wipe() throws {
        try db.exec("DELETE FROM meta; DELETE FROM rooms; DELETE FROM events; DELETE FROM state; DELETE FROM account_data; DELETE FROM receipts;")
        nextOrdering = 1
    }
}
