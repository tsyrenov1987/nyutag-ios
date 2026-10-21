// Нютаг. Отправка в зашифрованные комнаты: учёт устройств участников, сессии Olm к ним, раздача ключа
// комнаты (`m.room_key`) и шифрование событий Megolm. Плюс выгрузка ключей комнат в бэкап на сервере.

import Foundation
import NyutagCrypto

extension CryptoMachine {
    /// Ротация по умолчанию из спецификации: неделя или 100 сообщений.
    public static let defaultRotationPeriodMs = 604_800_000
    public static let defaultRotationMessages = 100

    func storing<T>(_ work: () async throws -> T) async throws(E2EEError) -> T {
        do { return try await work() } catch let error as E2EEError { throw error } catch { throw .store("\(error)") }
    }

    // MARK: Устройства

    /// Устройства пользователей с проверенными подписями. Списки, о смене которых сообщил /sync, и новые
    /// пользователи запрашиваются заново через `/keys/query`.
    public func devices(for users: [String]) async throws(E2EEError) -> [DeviceInfo] {
        let stale = try await storing { try await store.usersNeedingDeviceQuery(users) }
        for chunk in stride(from: 0, to: stale.count, by: 100).map({ Array(stale[$0..<min($0 + 100, stale.count)]) }) {
            let response: JSONValue
            do { response = try await client.queryKeys(userIDs: chunk) } catch { throw .server(error) }
            for user in chunk {
                // Сервер пользователя не ответил: список остаётся «грязным», спросим в следующий раз.
                guard let entries = response["device_keys", user]?.object else { continue }
                let identity = try await crossSigningIdentity(user, in: response)
                try await storing { try await store.saveCrossSigning(identity, userID: user) }
                let selfSigning = identity?.selfSigningKey
                let previous = try await storing { try await store.devices(userID: user) }
                let known = Dictionary(uniqueKeysWithValues: previous.map { ($0.deviceID, $0.ed25519Key) })
                var fresh: [DeviceInfo] = []
                for (deviceID, keys) in entries {
                    guard keys["user_id"]?.string == user, keys["device_id"]?.string == deviceID,
                          let ed = keys["keys", "ed25519:\(deviceID)"]?.string,
                          let curve = keys["keys", "curve25519:\(deviceID)"]?.string,
                          Self.verifySignature(keys, userID: user, keyID: deviceID, publicKey: ed) else { continue }
                    // Ключ подписи устройства не меняется; если сервер прислал другой, устройству не доверяем.
                    if let old = known[deviceID], old != ed { continue }
                    let crossSigned = selfSigning.map {
                        Self.verifySignature(keys, userID: user, keyID: $0, publicKey: $0)
                    } ?? false
                    fresh.append(DeviceInfo(userID: user, deviceID: deviceID, curve25519Key: curve, ed25519Key: ed,
                                            displayName: keys["unsigned", "device_display_name"]?.string,
                                            crossSigned: crossSigned))
                }
                try await storing { try await store.replaceDevices(fresh, userID: user) }
            }
        }
        var all: [DeviceInfo] = []
        for user in users { all += try await storing { try await store.devices(userID: user) } }
        return all
    }

    // MARK: Olm к устройствам

    /// Сессии Olm к устройствам: имеющиеся из базы, недостающие — по одноразовым ключам из `/keys/claim`.
    /// Устройства без ключей (сервер не выдал) в ответ не попадают.
    func olmSessions(for devices: [DeviceInfo]) async throws(E2EEError) -> [String: OlmSession] {
        var sessions: [String: OlmSession] = [:]
        var missing: [String: [String]] = [:]
        for device in devices {
            if let session = try await storing({ try await store.olmSessions(senderKey: device.curve25519Key) }).first {
                sessions[device.curve25519Key] = session
            } else {
                missing[device.userID, default: []].append(device.deviceID)
            }
        }
        guard !missing.isEmpty else { return sessions }
        let claimed: JSONValue
        do { claimed = try await client.claimKeys(missing) } catch { throw .server(error) }
        for device in devices where sessions[device.curve25519Key] == nil {
            guard let entry = claimed[device.userID, device.deviceID]?.object?.first(where: {
                      $0.key.hasPrefix("signed_curve25519:") }),
                  let oneTimeKey = entry.value["key"]?.string,
                  Self.verifySignature(entry.value, userID: device.userID, keyID: device.deviceID,
                                       publicKey: device.ed25519Key) else { continue }
            do {
                let session = try account.outboundSession(theirIdentityKey: device.curve25519Key, theirOneTimeKey: oneTimeKey)
                try await store.saveOlmSession(session)
                sessions[device.curve25519Key] = session
            } catch let error as CryptoError {
                throw .crypto(error)
            } catch {
                throw .store("\(error)")
            }
        }
        return sessions
    }

    /// Содержимое `m.room.encrypted` для одного устройства (to-device, Olm).
    func olmEncrypt(type: String, content: JSONValue, to device: DeviceInfo,
                    session: inout OlmSession) throws(E2EEError) -> JSONValue {
        let payload: JSONValue = [
            "type": .string(type), "content": content,
            "sender": .string(userID), "sender_device": .string(deviceID),
            "recipient": .string(device.userID), "recipient_keys": ["ed25519": .string(device.ed25519Key)],
            "keys": ["ed25519": .string(ed25519Key)],
        ]
        let sealed: OlmEncrypted
        do { sealed = try session.encrypt(try payload.data()) } catch let error as CryptoError {
            throw .crypto(error)
        } catch {
            throw .badPayload("\(error)")
        }
        return [
            "algorithm": .string(Self.olmAlgorithm), "sender_key": .string(curve25519Key),
            "ciphertext": .object([device.curve25519Key: ["type": .int(sealed.type.rawValue), "body": .string(sealed.body)]]),
        ]
    }

    /// Отправить одно to-device событие каждому устройству, шифруя Olm. Возвращает устройства, которым ушло.
    @discardableResult
    public func sendEncryptedToDevice(type: String, content: JSONValue,
                                      to devices: [DeviceInfo]) async throws(E2EEError) -> [DeviceInfo] {
        let sessions = try await olmSessions(for: devices)
        var sent: [DeviceInfo] = []
        var batches: [[String: [String: JSONValue]]] = [[:]]
        for device in devices {
            guard var session = sessions[device.curve25519Key] else { continue }
            if sent.count > 0, sent.count % 250 == 0 { batches.append([:]) }
            batches[batches.count - 1][device.userID, default: [:]][device.deviceID] =
                try olmEncrypt(type: type, content: content, to: device, session: &session)
            let used = session
            try await storing { try await store.saveOlmSession(used) }
            sent.append(device)
        }
        for batch in batches where !batch.isEmpty {
            do { try await client.sendToDevice(type: EventType.encrypted, messages: batch) } catch { throw .server(error) }
        }
        return sent
    }

    // MARK: Комнаты

    /// Устройства, которым положен ключ комнаты: все участники (и приглашённые, если история им видна), кроме этого устройства.
    func recipients(roomID: String) async throws(E2EEError) -> [DeviceInfo] {
        let members: [Event]
        do { members = try await client.members(roomID: roomID) } catch { throw .server(error) }
        let visibility = try await storing {
            try await store.state(roomID, type: "m.room.history_visibility", stateKey: "")?["history_visibility"]?.string
        }
        let users = Set(members.compactMap { event -> String? in
            guard event.type == EventType.member, let user = event.stateKey else { return nil }
            switch event.content["membership"]?.string {
            case "join": return user
            case "invite": return visibility == "joined" ? nil : user
            default: return nil
            }
        })
        return try await devices(for: users.sorted()).filter { !($0.userID == userID && $0.deviceID == deviceID) }
    }

    /// Готовит исходящую сессию комнаты: меняет её, если пора (срок, число сообщений, ушёл участник или устройство),
    /// и раздаёт ключ устройствам, у которых его ещё нет.
    public func shareRoomKey(roomID: String) async throws(E2EEError) {
        let devices = try await recipients(roomID: roomID)
        let settings = try await storing { try await store.state(roomID, type: EventType.encryption, stateKey: "") }
        let periodMs = settings?["rotation_period_ms"]?.int ?? Self.defaultRotationPeriodMs
        let maxMessages = settings?["rotation_period_msgs"]?.int ?? Self.defaultRotationMessages
        let current = Dictionary(devices.map { ("\($0.userID)|\($0.deviceID)", $0.curve25519Key) },
                                 uniquingKeysWith: { first, _ in first })

        var record = try await storing { try await store.outbound(roomID: roomID) }
        if let existing = record {
            let expired = Date().timeIntervalSince(existing.createdAt) * 1000 >= Double(periodMs)
                || existing.messageCount >= maxMessages
            // Ключ видело устройство, которого в комнате больше нет (или с другим ключом): дальше ему читать нельзя.
            let someoneLeft = existing.sharedWith.contains { current[$0.key] != $0.value }
            if expired || someoneLeft { record = nil }
        }
        if record == nil {
            let session = MegolmOutboundSession()
            record = OutboundRecord(session)
            // Своя входящая копия: читать свои же сообщения и выгрузить ключ в бэкап.
            do {
                let inbound = try MegolmInboundSession(sessionKey: session.sessionKey())
                try await store.saveMegolmSession(inbound, roomID: roomID, senderKey: curve25519Key,
                                                  claimedEd25519: ed25519Key)
                try await store.saveOutbound(record, roomID: roomID)
            } catch let error as CryptoError {
                throw .crypto(error)
            } catch {
                throw .store("\(error)")
            }
        }
        guard var record else { return }
        let pending = devices.filter { record.sharedWith["\($0.userID)|\($0.deviceID)"] != $0.curve25519Key }
        guard !pending.isEmpty else { return }
        let session: MegolmOutboundSession
        do { session = try record.session() } catch { throw .store("\(error)") }
        let roomKey: JSONValue = [
            "algorithm": .string(Self.megolmAlgorithm), "room_id": .string(roomID),
            "session_id": .string(session.sessionID), "session_key": .string(session.sessionKey()),
        ]
        let sent = try await sendEncryptedToDevice(type: EventType.roomKey, content: roomKey, to: pending)
        for device in sent { record.sharedWith["\(device.userID)|\(device.deviceID)"] = device.curve25519Key }
        // Без одноразовых ключей канал Olm не открыть: говорим устройству, почему ключа нет (один раз).
        let told = Set(record.withheldFrom ?? [])
        let unreachable = pending.filter {
            record.sharedWith["\($0.userID)|\($0.deviceID)"] == nil && !told.contains("\($0.userID)|\($0.deviceID)")
        }
        if !unreachable.isEmpty {
            try await sendWithheld(unreachable, roomID: roomID, sessionID: session.sessionID, code: "m.no_olm",
                                   reason: "Нет одноразовых ключей для устройства")
            record.withheldFrom = Array(told) + unreachable.map { "\($0.userID)|\($0.deviceID)" }
        }
        let shared = record
        try await storing { try await store.saveOutbound(shared, roomID: roomID) }
    }

    /// Шифрует событие для комнаты: содержимое для `PUT /rooms/{id}/send/m.room.encrypted/{txn}`.
    /// Перед этим раздаёт ключ комнаты тем, у кого его нет. Вызовы для одной комнаты идут по очереди.
    public func encrypt(roomID: String, type: String, content: JSONValue) async throws(E2EEError) -> JSONValue {
        await lockRoom(roomID)
        defer { unlockRoom(roomID) }
        try await shareRoomKey(roomID: roomID)
        guard let record = try await storing({ try await store.outbound(roomID: roomID) }) else {
            throw .missingSession(sessionID: "")
        }
        var session: MegolmOutboundSession
        do { session = try record.session() } catch { throw .store("\(error)") }
        let plaintext: JSONValue = ["type": .string(type), "content": content, "room_id": .string(roomID)]
        let ciphertext: String
        do { ciphertext = try session.encrypt(try plaintext.data()) } catch let error as CryptoError {
            throw .crypto(error)
        } catch {
            throw .badPayload("\(error)")
        }
        let next = OutboundRecord(session, messageCount: record.messageCount + 1, sharedWith: record.sharedWith,
                                  withheldFrom: record.withheldFrom)
        try await storing { try await store.saveOutbound(next, roomID: roomID) }
        var sealed: [String: JSONValue] = [
            "algorithm": .string(Self.megolmAlgorithm), "sender_key": .string(curve25519Key),
            "ciphertext": .string(ciphertext), "session_id": .string(session.sessionID), "device_id": .string(deviceID),
        ]
        // Связь с другой репликой (правка, реакция, ответ) остаётся снаружи: по ней сервер группирует события.
        if let relation = content["m.relates_to"] { sealed["m.relates_to"] = relation }
        return .object(sealed)
    }

    /// Шифрует и отправляет событие в комнату. Возвращает `event_id`.
    @discardableResult
    public func sendEncrypted(roomID: String, type: String, content: JSONValue,
                              transactionID: String = TransactionID.make()) async throws(E2EEError) -> String {
        let sealed = try await encrypt(roomID: roomID, type: type, content: content)
        do {
            return try await client.send(roomID: roomID, type: EventType.encrypted, content: sealed, transactionID: transactionID)
        } catch {
            throw .server(error)
        }
    }

    /// Забыть исходящую сессию комнаты: следующее сообщение пойдёт с новым ключом.
    public func discardRoomKey(roomID: String) async throws(E2EEError) {
        try await storing { try await store.saveOutbound(nil, roomID: roomID) }
    }

    // MARK: Бэкап

    /// Выгружает в бэкап на сервере ключи комнат, которых там ещё нет. Нужен ключ бэкапа, поднятый `restoreBackup`.
    /// Возвращает число выгруженных сессий.
    @discardableResult
    public func uploadRoomKeysToBackup() async throws(E2EEError) -> Int {
        guard let version = try await storing({ try await store.meta("e2ee_backup_version") }),
              let raw = try await storing({ try await store.cryptoBlob("backup_key") }) else { throw .noBackup }
        let publicKey: String
        do { publicKey = try BackupKey(privateKey: raw).publicKeyBase64 } catch { throw .crypto(error) }
        var uploaded = 0
        while true {
            let batch = try await storing { try await store.megolmSessionsNotBackedUp(limit: 200) }
            guard !batch.isEmpty else { break }
            var rooms: [String: [String: JSONValue]] = [:]
            for stored in batch {
                var claimed: [String: JSONValue] = [:]
                if let ed = stored.claimedEd25519 { claimed["ed25519"] = .string(ed) }
                let sealed: BackupSessionData
                do {
                    let plaintext: JSONValue = [
                        "algorithm": .string(Self.megolmAlgorithm), "sender_key": .string(stored.senderKey),
                        "session_key": .string(try stored.session.export()), "sender_claimed_keys": .object(claimed),
                        "forwarding_curve25519_key_chain": [],
                    ]
                    sealed = try BackupKey.encrypt(try plaintext.data(), publicKey: publicKey)
                } catch let error as CryptoError {
                    throw .crypto(error)
                } catch {
                    throw .badPayload("\(error)")
                }
                rooms[stored.roomID, default: [:]][stored.session.sessionID] = [
                    "first_message_index": .int(Int(stored.session.firstKnownIndex)), "forwarded_count": 0,
                    "is_verified": .bool(stored.session.isVerified),
                    "session_data": ["ephemeral": .string(sealed.ephemeral), "ciphertext": .string(sealed.ciphertext),
                                     "mac": .string(sealed.mac)],
                ]
            }
            do {
                _ = try await client.uploadBackupKeys(version: version, rooms: rooms)
            } catch {
                // Бэкап на сервере заменили: старый ключ больше не годится, нужен новый recovery-код.
                if error.errcode == "M_WRONG_ROOM_KEYS_VERSION" {
                    try await storing { try await store.setMeta("e2ee_backup_version", nil) }
                    throw .noBackup
                }
                throw .server(error)
            }
            try await storing { try await store.markMegolmBackedUp(batch) }
            uploaded += batch.count
        }
        return uploaded
    }

    // MARK: Очередь по комнате

    func lockRoom(_ roomID: String) async {
        while busyRooms.contains(roomID) {
            await withCheckedContinuation { roomWaiters[roomID, default: []].append($0) }
        }
        busyRooms.insert(roomID)
    }

    func unlockRoom(_ roomID: String) {
        busyRooms.remove(roomID)
        for waiter in roomWaiters.removeValue(forKey: roomID) ?? [] { waiter.resume() }
    }
}
