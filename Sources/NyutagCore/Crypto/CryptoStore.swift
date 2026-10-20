// Нютаг. Хранение ключей шифрования в базе аккаунта: ключи устройства, сессии Olm, входящие сессии Megolm,
// использованные индексы сообщений (защита от повтора).

import Foundation
import NyutagCrypto

/// Входящая сессия Megolm вместе с тем, откуда она и к какой комнате относится.
public struct StoredMegolmSession: Sendable {
    public let roomID: String
    public let senderKey: String
    public let session: MegolmInboundSession
    public let backedUp: Bool
    /// Ключ подписи устройства отправителя, как он его заявил (`keys.ed25519` в `m.room_key`).
    public let claimedEd25519: String?
}

/// Устройство пользователя из `/keys/query` с проверенной подписью.
public struct DeviceInfo: Sendable, Equatable {
    public let userID: String
    public let deviceID: String
    public let curve25519Key: String
    public let ed25519Key: String
    public let displayName: String?
}

/// Исходящая сессия Megolm комнаты и кому её ключ уже отдан.
struct OutboundRecord: Codable, Sendable {
    var ratchet: Data
    var counter: UInt32
    var signingKey: Data
    var createdAt: Date
    var messageCount: Int
    /// "пользователь|устройство" → ключ Curve25519 устройства на момент отправки.
    var sharedWith: [String: String]

    init(_ session: MegolmOutboundSession, messageCount: Int = 0, sharedWith: [String: String] = [:]) {
        ratchet = session.ratchet.data
        counter = session.ratchet.counter
        signingKey = session.signingKey.rawRepresentation
        createdAt = session.createdAt
        self.messageCount = messageCount
        self.sharedWith = sharedWith
    }

    func session() throws -> MegolmOutboundSession {
        MegolmOutboundSession(ratchet: try MegolmRatchet(data: ratchet, counter: counter),
                              signingKey: try Ed25519KeyPair(rawRepresentation: signingKey), createdAt: createdAt)
    }
}

extension Store {
    // MARK: Ключи устройства

    func cryptoBlob(_ key: String) throws -> Data? {
        try db.scalar("SELECT value FROM crypto_meta WHERE key = ?", .text(key))?.data
    }

    func setCryptoBlob(_ key: String, _ value: Data?) throws {
        if let value {
            try db.run("INSERT INTO crypto_meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                       .text(key), .blob(value))
        } else {
            try db.run("DELETE FROM crypto_meta WHERE key = ?", .text(key))
        }
    }

    // MARK: Olm

    func olmSessions(senderKey: String) throws -> [OlmSession] {
        try db.query("SELECT data FROM olm_sessions WHERE sender_key = ? ORDER BY last_used DESC", .text(senderKey)) { row in
            try JSONDecoder().decode(OlmSession.self, from: row.value(0).data ?? Data())
        }
    }

    func saveOlmSession(_ session: OlmSession) throws {
        let data = try JSONEncoder().encode(session)
        try db.run("""
            INSERT INTO olm_sessions(session_id, sender_key, data, last_used) VALUES(?, ?, ?, ?)
            ON CONFLICT(session_id) DO UPDATE SET data = excluded.data, last_used = excluded.last_used
            """, .text(session.sessionID), .text(session.theirIdentityKey), .blob(data),
                   .real(session.lastUsed.timeIntervalSince1970))
    }

    // MARK: Megolm

    /// Сохранить сессию; если такая уже есть, оставить ту, что начинается с меньшего индекса
    /// (при равенстве — проверенную подписью отправителя).
    @discardableResult
    func saveMegolmSession(_ session: MegolmInboundSession, roomID: String, senderKey: String,
                           backedUp: Bool = false, claimedEd25519: String? = nil) throws -> Bool {
        if let existing = try megolmSession(senderKey: senderKey, sessionID: session.sessionID) {
            let better = session.firstKnownIndex < existing.session.firstKnownIndex
                || (session.firstKnownIndex == existing.session.firstKnownIndex && session.isVerified && !existing.session.isVerified)
            guard better else { return false }
        }
        try db.run("""
            INSERT INTO megolm_inbound(sender_key, session_id, room_id, exported, first_index, verified, backed_up,
                claimed_ed25519) VALUES(?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(sender_key, session_id) DO UPDATE SET room_id = excluded.room_id, exported = excluded.exported,
                first_index = excluded.first_index, verified = excluded.verified, backed_up = excluded.backed_up,
                claimed_ed25519 = COALESCE(excluded.claimed_ed25519, claimed_ed25519)
            """, [.text(senderKey), .text(session.sessionID), .text(roomID), .text(try session.export()),
                  .integer(Int64(session.firstKnownIndex)), .integer(session.isVerified ? 1 : 0), .integer(backedUp ? 1 : 0),
                  .init(claimedEd25519)])
        return true
    }

    func megolmSession(senderKey: String, sessionID: String) throws -> StoredMegolmSession? {
        try db.query("""
            SELECT room_id, exported, verified, backed_up, claimed_ed25519 FROM megolm_inbound
            WHERE sender_key = ? AND session_id = ?
            """, .text(senderKey), .text(sessionID)) { row in
            try Self.megolm(row, senderKey: senderKey)
        }.first
    }

    /// Сессия по одному session_id: в новых событиях `sender_key` может отсутствовать.
    func megolmSession(sessionID: String) throws -> StoredMegolmSession? {
        try db.query("""
            SELECT room_id, exported, verified, backed_up, claimed_ed25519, sender_key FROM megolm_inbound WHERE session_id = ?
            """, .text(sessionID)) { row in
            try Self.megolm(row, senderKey: row.value(5).string ?? "")
        }.first
    }

    func megolmSessionCount() throws -> Int {
        try db.scalar("SELECT COUNT(*) FROM megolm_inbound")?.int ?? 0
    }

    private static func megolm(_ row: SQLite.Row, senderKey: String) throws -> StoredMegolmSession {
        let exported = row.value(1).string ?? ""
        let restored = try MegolmInboundSession(exportedKey: exported)
        let session = MegolmInboundSession(initialRatchet: restored.initialRatchet, signingKey: restored.signingKey,
                                           isVerified: row.value(2).int == 1)
        return StoredMegolmSession(roomID: row.value(0).string ?? "", senderKey: senderKey, session: session,
                                   backedUp: row.value(3).int == 1, claimedEd25519: row.value(4).string)
    }

    /// Сессии, которых ещё нет в бэкапе на сервере.
    func megolmSessionsNotBackedUp(limit: Int) throws -> [StoredMegolmSession] {
        try db.query("""
            SELECT room_id, exported, verified, backed_up, claimed_ed25519, sender_key FROM megolm_inbound
            WHERE backed_up = 0 LIMIT ?
            """, .integer(Int64(limit))) { row in
            try Self.megolm(row, senderKey: row.value(5).string ?? "")
        }
    }

    func markMegolmBackedUp(_ sessions: [StoredMegolmSession]) throws {
        for stored in sessions {
            try db.run("UPDATE megolm_inbound SET backed_up = 1 WHERE sender_key = ? AND session_id = ?",
                       .text(stored.senderKey), .text(stored.session.sessionID))
        }
    }

    /// Новая версия бэкапа на сервере: всё нужно выгрузить заново.
    func resetMegolmBackedUp() throws {
        try db.run("UPDATE megolm_inbound SET backed_up = 0")
    }

    /// Запомнить индекс; `false`, если этот индекс сессии уже был у другого события (повтор).
    func markMegolmIndex(sessionID: String, index: UInt32, eventID: String) throws -> Bool {
        if let seen = try db.scalar("SELECT event_id FROM megolm_seen WHERE session_id = ? AND message_index = ?",
                                    .text(sessionID), .integer(Int64(index)))?.string {
            return seen == eventID
        }
        try db.run("INSERT INTO megolm_seen(session_id, message_index, event_id) VALUES(?, ?, ?)",
                   .text(sessionID), .integer(Int64(index)), .text(eventID))
        return true
    }
}

extension Store {
    // MARK: Устройства

    /// Пользователи, чьи списки устройств надо (пере)запросить: новые и отмеченные в `device_lists.changed`.
    func usersNeedingDeviceQuery(_ users: [String]) throws -> [String] {
        try users.filter { user in
            (try db.scalar("SELECT dirty FROM tracked_users WHERE user_id = ?", .text(user))?.int ?? 1) == 1
        }
    }

    func markDeviceListsChanged(_ users: [String]) throws {
        for user in users {
            try db.run("UPDATE tracked_users SET dirty = 1 WHERE user_id = ?", .text(user))
        }
    }

    /// Свежий список устройств пользователя: заменяет прежний целиком.
    func replaceDevices(_ devices: [DeviceInfo], userID: String) throws {
        try db.run("DELETE FROM devices WHERE user_id = ?", .text(userID))
        for device in devices {
            let extra: JSONValue = ["display_name": device.displayName.map(JSONValue.string) ?? .null]
            try db.run("INSERT INTO devices(user_id, device_id, curve_key, ed_key, keys) VALUES(?, ?, ?, ?, ?)",
                       .text(userID), .text(device.deviceID), .text(device.curve25519Key), .text(device.ed25519Key),
                       .init(json: extra))
        }
        try db.run("INSERT INTO tracked_users(user_id, dirty) VALUES(?, 0) ON CONFLICT(user_id) DO UPDATE SET dirty = 0",
                   .text(userID))
    }

    func devices(userID: String) throws -> [DeviceInfo] {
        try db.query("SELECT device_id, curve_key, ed_key, keys FROM devices WHERE user_id = ? ORDER BY device_id",
                     .text(userID)) { row in
            DeviceInfo(userID: userID, deviceID: row.string(0) ?? "", curve25519Key: row.string(1) ?? "",
                       ed25519Key: row.string(2) ?? "", displayName: row.value(3).json?["display_name"]?.string)
        }
    }

    // MARK: Исходящие сессии

    func outbound(roomID: String) throws -> OutboundRecord? {
        guard let data = try db.scalar("SELECT data FROM megolm_outbound WHERE room_id = ?", .text(roomID))?.data else {
            return nil
        }
        return try JSONDecoder().decode(OutboundRecord.self, from: data)
    }

    func saveOutbound(_ record: OutboundRecord?, roomID: String) throws {
        if let record {
            try db.run("""
                INSERT INTO megolm_outbound(room_id, data) VALUES(?, ?) ON CONFLICT(room_id) DO UPDATE SET data = excluded.data
                """, .text(roomID), .blob(try JSONEncoder().encode(record)))
        } else {
            try db.run("DELETE FROM megolm_outbound WHERE room_id = ?", .text(roomID))
        }
    }
}
