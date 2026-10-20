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
                           backedUp: Bool = false) throws -> Bool {
        if let existing = try megolmSession(senderKey: senderKey, sessionID: session.sessionID) {
            let better = session.firstKnownIndex < existing.session.firstKnownIndex
                || (session.firstKnownIndex == existing.session.firstKnownIndex && session.isVerified && !existing.session.isVerified)
            guard better else { return false }
        }
        try db.run("""
            INSERT INTO megolm_inbound(sender_key, session_id, room_id, exported, first_index, verified, backed_up)
            VALUES(?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(sender_key, session_id) DO UPDATE SET room_id = excluded.room_id, exported = excluded.exported,
                first_index = excluded.first_index, verified = excluded.verified, backed_up = excluded.backed_up
            """, .text(senderKey), .text(session.sessionID), .text(roomID), .text(try session.export()),
                   .integer(Int64(session.firstKnownIndex)), .integer(session.isVerified ? 1 : 0), .integer(backedUp ? 1 : 0))
        return true
    }

    func megolmSession(senderKey: String, sessionID: String) throws -> StoredMegolmSession? {
        try db.query("""
            SELECT room_id, exported, verified, backed_up FROM megolm_inbound WHERE sender_key = ? AND session_id = ?
            """, .text(senderKey), .text(sessionID)) { row in
            try Self.megolm(row, senderKey: senderKey)
        }.first
    }

    /// Сессия по одному session_id: в новых событиях `sender_key` может отсутствовать.
    func megolmSession(sessionID: String) throws -> StoredMegolmSession? {
        try db.query("""
            SELECT room_id, exported, verified, backed_up, sender_key FROM megolm_inbound WHERE session_id = ?
            """, .text(sessionID)) { row in
            try Self.megolm(row, senderKey: row.value(4).string ?? "")
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
                                   backedUp: row.value(3).int == 1)
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
