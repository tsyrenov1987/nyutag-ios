// Нютаг. Эндпоинты ключей шифрования: загрузка и запрос ключей устройств, одноразовые ключи,
// to-device сообщения, бэкап ключей комнат.

import Foundation

/// Версия бэкапа ключей на сервере.
public struct BackupVersion: Sendable, Equatable {
    public let version: String
    public let algorithm: String
    public let publicKey: String?
    public let count: Int
    public let etag: String?
    public let authData: JSONValue
}

public extension MatrixClient {
    /// `/keys/upload`: ключи устройства, одноразовые и запасные. Возвращает счётчики одноразовых ключей на сервере.
    func uploadKeys(deviceKeys: JSONValue? = nil, oneTimeKeys: JSONValue? = nil,
                    fallbackKeys: JSONValue? = nil) async throws(MatrixError) -> [String: Int] {
        var body: [String: JSONValue] = [:]
        if let deviceKeys { body["device_keys"] = deviceKeys }
        if let oneTimeKeys { body["one_time_keys"] = oneTimeKeys }
        if let fallbackKeys { body["fallback_keys"] = fallbackKeys }
        let json: JSONValue = try await request(.post, "keys/upload", body: .object(body))
        return (json["one_time_key_counts"]?.object ?? [:]).compactMapValues(\.int)
    }

    /// `/keys/query`: ключи устройств и кросс-подписи пользователей (весь ответ как есть).
    func queryKeys(userIDs: [String]) async throws(MatrixError) -> JSONValue {
        var devices: [String: JSONValue] = [:]
        for user in userIDs { devices[user] = .array([]) }
        return try await request(.post, "keys/query", body: ["device_keys": .object(devices)])
    }

    /// `/keys/claim`: по одному одноразовому ключу на устройство. Ответ: пользователь → устройство → {id: ключ}.
    func claimKeys(_ devices: [String: [String]],
                   algorithm: String = "signed_curve25519") async throws(MatrixError) -> JSONValue {
        var body: [String: JSONValue] = [:]
        for (user, ids) in devices {
            body[user] = .object(Dictionary(uniqueKeysWithValues: ids.map { ($0, JSONValue.string(algorithm)) }))
        }
        let json: JSONValue = try await request(.post, "keys/claim", body: ["one_time_keys": .object(body)])
        return json["one_time_keys"] ?? .object([:])
    }

    /// `/sendToDevice`: пользователь → устройство (или `*`) → содержимое.
    func sendToDevice(type: String, messages: [String: [String: JSONValue]],
                      transactionID: String = TransactionID.make()) async throws(MatrixError) {
        let body = JSONValue.object(messages.mapValues { .object($0) })
        let _: EmptyResponse = try await request(.put, "sendToDevice/\(type)/\(transactionID)", body: ["messages": body])
    }

    /// Текущая версия бэкапа; nil, если бэкапа нет.
    func backupVersion() async throws(MatrixError) -> BackupVersion? {
        let json: JSONValue
        do throws(MatrixError) {
            json = try await request(.get, "room_keys/version")
        } catch where error.errcode == "M_NOT_FOUND" {
            return nil
        }
        guard let version = json["version"]?.string, let algorithm = json["algorithm"]?.string else {
            throw MatrixError(.decoding("room_keys/version"))
        }
        return BackupVersion(version: version, algorithm: algorithm, publicKey: json["auth_data", "public_key"]?.string,
                             count: json["count"]?.int ?? 0, etag: json["etag"]?.string,
                             authData: json["auth_data"] ?? .object([:]))
    }

    /// Все ключи бэкапа: комната → session_id → запись (`first_message_index`, `session_data` …).
    func backupKeys(version: String) async throws(MatrixError) -> [String: [String: JSONValue]] {
        let json: JSONValue = try await request(.get, "room_keys/keys", query: ["version": version])
        var result: [String: [String: JSONValue]] = [:]
        for (roomID, room) in json["rooms"]?.object ?? [:] {
            result[roomID] = room["sessions"]?.object ?? [:]
        }
        return result
    }

    /// Ключи одной комнаты из бэкапа (докачка, когда сессии нет).
    func backupKey(version: String, roomID: String, sessionID: String) async throws(MatrixError) -> JSONValue? {
        do throws(MatrixError) {
            return try await request(.get, "room_keys/keys/\(roomID)/\(sessionID)", query: ["version": version])
        } catch where error.errcode == "M_NOT_FOUND" {
            return nil
        }
    }

    /// Загрузка ключей в бэкап: комната → session_id → запись.
    func uploadBackupKeys(version: String, rooms: [String: [String: JSONValue]]) async throws(MatrixError) -> Int {
        let body = JSONValue.object(["rooms": .object(rooms.mapValues { ["sessions": .object($0)] })])
        let json: JSONValue = try await request(.put, "room_keys/keys", query: ["version": version], body: body)
        return json["count"]?.int ?? 0
    }

    /// `/keys/signatures/upload`: пользователь → ключ (устройство или публичный ключ кросс-подписи) → объект с подписью.
    /// Возвращает `failures`.
    func uploadSignatures(_ signed: [String: [String: JSONValue]]) async throws(MatrixError) -> JSONValue {
        let body = JSONValue.object(signed.mapValues { .object($0) })
        let json: JSONValue = try await request(.post, "keys/signatures/upload", body: body)
        return json["failures"] ?? .object([:])
    }

    /// `/keys/device_signing/upload`: ключи кросс-подписи. Сервер может потребовать подтверждение паролем:
    /// тогда первый ответ — 401 с `session`, и запрос повторяется с `auth`.
    func uploadCrossSigningKeys(master: JSONValue, selfSigning: JSONValue, userSigning: JSONValue,
                                auth: JSONValue? = nil) async throws(MatrixError) {
        var body: [String: JSONValue] = ["master_key": master, "self_signing_key": selfSigning,
                                         "user_signing_key": userSigning]
        if let auth { body["auth"] = auth }
        let _: EmptyResponse = try await request(.post, "keys/device_signing/upload", body: .object(body))
    }
}
