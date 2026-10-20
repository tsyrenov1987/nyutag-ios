// Нютаг. Шифрование аккаунта на этом устройстве: ключи устройства и их публикация, приём to-device
// сообщений Olm (ключи комнат), расшифровка событий комнат Megolm, восстановление ключей из бэкапа.

import Foundation
import NyutagCrypto

public enum E2EEError: Error, Sendable, Equatable {
    case crypto(CryptoError)
    case server(MatrixError)
    case store(String)
    /// Нет ключа сессии: ждать `m.room_key`, запросить у своих устройств или взять из бэкапа.
    case missingSession(sessionID: String)
    case unsupportedAlgorithm(String)
    case badPayload(String)
    /// Тот же индекс сессии уже был у другого события.
    case replay
    case noBackup
    case wrongRecoveryKey
    /// Отправитель отказал в ключе (`m.room_key.withheld`): `m.no_olm`, `m.unverified`, `m.blacklisted` …
    case withheld(code: String, reason: String?)
}

/// Расшифрованное событие комнаты и откуда взялся ключ.
public struct DecryptedEvent: Sendable {
    public let event: Event
    public let senderKey: String
    public let sessionID: String
    public let messageIndex: UInt32
    /// Ключ пришёл с подписью отправителя (`m.room_key`), а не из бэкапа или пересылки.
    public let isVerifiedSession: Bool
}

public actor CryptoMachine: SyncObserver {
    public static let olmAlgorithm = "m.olm.v1.curve25519-aes-sha2"
    public static let megolmAlgorithm = "m.megolm.v1.aes-sha2"
    public static let backupAlgorithm = "m.megolm_backup.v1.curve25519-aes-sha2"

    public nonisolated let userID: String
    public nonisolated let deviceID: String
    public nonisolated let curve25519Key: String
    public nonisolated let ed25519Key: String
    let client: MatrixClient
    let store: Store
    var account: OlmAccount
    /// Комнаты, где сейчас идёт шифрование, и кто ждёт своей очереди.
    var busyRooms: Set<String> = []
    var roomWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    /// Идущие проверки по эмодзи; ключи SAS живут только в памяти.
    var verifications: [String: VerificationSession] = [:]

    public init(client: MatrixClient, store: Store, session: Session) async throws(E2EEError) {
        self.client = client
        self.store = store
        userID = session.userID
        deviceID = session.deviceID
        do {
            if let blob = try await store.cryptoBlob("account") {
                account = try JSONDecoder().decode(OlmAccount.self, from: blob)
            } else {
                account = OlmAccount()
                try await store.setCryptoBlob("account", JSONEncoder().encode(account))
            }
        } catch {
            throw .store("\(error)")
        }
        curve25519Key = account.curve25519Key
        ed25519Key = account.ed25519Key
    }

    private func saveAccount() async throws(E2EEError) {
        do { try await store.setCryptoBlob("account", JSONEncoder().encode(account)) } catch { throw .store("\(error)") }
    }

    // MARK: Подписи

    /// Подпись объекта ключом устройства: canonical JSON без `signatures` и `unsigned`, подпись в `signatures`.
    public func sign(_ object: JSONValue) -> JSONValue {
        guard case .object(var fields) = object else { return object }
        let unsigned = fields.removeValue(forKey: "unsigned")
        var signatures = fields.removeValue(forKey: "signatures")?.object ?? [:]
        let signature = account.sign(Data(JSONValue.object(fields).canonicalJSON().utf8))
        var mine = signatures[userID]?.object ?? [:]
        mine["ed25519:\(deviceID)"] = .string(signature)
        signatures[userID] = .object(mine)
        fields["signatures"] = .object(signatures)
        if let unsigned { fields["unsigned"] = unsigned }
        return .object(fields)
    }

    /// Проверка подписи `ed25519:<keyID>` пользователя `userID` открытым ключом.
    public static func verifySignature(_ object: JSONValue, userID: String, keyID: String, publicKey: String) -> Bool {
        guard case .object(var fields) = object,
              let signature = fields["signatures"]?[userID]?["ed25519:\(keyID)"]?.string,
              let signatureData = try? Base64.decode(signature), let key = try? Base64.decode(publicKey) else { return false }
        fields["signatures"] = nil
        fields["unsigned"] = nil
        return Ed25519KeyPair.verify(signature: signatureData, message: Data(JSONValue.object(fields).canonicalJSON().utf8),
                                     publicKey: key)
    }

    /// Ключи устройства для `/keys/upload`, подписанные.
    public func deviceKeys() -> JSONValue {
        sign([
            "user_id": .string(userID),
            "device_id": .string(deviceID),
            "algorithms": [.string(Self.olmAlgorithm), .string(Self.megolmAlgorithm)],
            "keys": .object([
                "curve25519:\(deviceID)": .string(curve25519Key),
                "ed25519:\(deviceID)": .string(ed25519Key),
            ]),
        ])
    }

    // MARK: Публикация ключей

    /// Публикует ключи устройства (один раз), добивает одноразовые ключи до половины лимита сервера,
    /// заводит запасной ключ. `serverCount` — `signed_curve25519` из /sync или nil, если неизвестно.
    @discardableResult
    public func publishKeys(serverCount: Int?) async throws(E2EEError) -> Int {
        let published = (try? await store.meta("e2ee_device_keys_published")) == "1"
        let target = OlmAccount.maxOneTimeKeys / 2
        let current = serverCount ?? 0
        if current < target, account.unpublishedOneTimeKeys.isEmpty {
            account.generateOneTimeKeys(target - current)
        }
        if account.unpublishedFallbackKey == nil, (try? await store.meta("e2ee_fallback_published")) != "1" {
            account.generateFallbackKey()
        }
        try await saveAccount()
        let oneTime = account.unpublishedOneTimeKeys
        let fallback = account.unpublishedFallbackKey
        guard !published || !oneTime.isEmpty || fallback != nil else { return current }

        var otks: [String: JSONValue] = [:]
        for (id, key) in oneTime { otks["signed_curve25519:\(id)"] = sign(["key": .string(key)]) }
        var fallbackKeys: [String: JSONValue] = [:]
        if let fallback {
            fallbackKeys["signed_curve25519:\(fallback.id)"] = sign(["key": .string(fallback.key), "fallback": true])
        }
        let counts: [String: Int]
        do {
            counts = try await client.uploadKeys(deviceKeys: published ? nil : deviceKeys(),
                                                 oneTimeKeys: otks.isEmpty ? nil : .object(otks),
                                                 fallbackKeys: fallbackKeys.isEmpty ? nil : .object(fallbackKeys))
        } catch {
            throw .server(error)
        }
        account.markKeysPublished()
        try await saveAccount()
        do {
            try await store.setMeta("e2ee_device_keys_published", "1")
            if fallback != nil { try await store.setMeta("e2ee_fallback_published", "1") }
        } catch {
            throw .store("\(error)")
        }
        return counts["signed_curve25519"] ?? 0
    }

    // MARK: To-device

    public func syncDidReceive(_ update: SyncUpdate) async {
        let changed = update.response.deviceListsChanged + update.response.deviceListsLeft
        if !changed.isEmpty { try? await store.markDeviceListsChanged(changed) }
        _ = await receiveToDevice(update.response.toDevice)
        if let count = update.response.oneTimeKeysCount["signed_curve25519"] ?? (update.isInitial ? 0 : nil),
           count < OlmAccount.maxOneTimeKeys / 2 {
            _ = try? await publishKeys(serverCount: count)
        }
        // Новые ключи комнат (свои и полученные) уходят в бэкап, если ключ бэкапа на этом устройстве есть.
        if (try? await store.cryptoBlob("backup_key")) != nil { _ = try? await uploadRoomKeysToBackup() }
    }

    /// Расшифровывает to-device сообщения Olm и принимает ключи комнат. Возвращает расшифрованные события.
    public func receiveToDevice(_ events: [Event]) async -> [Event] {
        var decrypted: [Event] = []
        for event in events {
            switch event.type {
            case EventType.roomKeyRequest: _ = try? await answerRoomKeyRequest(event)
            case Self.withheldType: await acceptWithheld(event)
            case let type where VerificationEvent.all.contains(type): await receiveVerification(event)
            default: break
            }
        }
        for event in events where event.type == EventType.encrypted {
            guard let inner = try? await decryptToDevice(event) else { continue }
            decrypted.append(inner)
            switch inner.type {
            case EventType.roomKey: try? await acceptRoomKey(inner)
            case EventType.forwardedRoomKey: try? await acceptForwardedRoomKey(inner)
            case let type where VerificationEvent.all.contains(type): await receiveVerification(inner)
            default: break
            }
        }
        return decrypted
    }

    func decryptToDevice(_ event: Event) async throws(E2EEError) -> Event {
        let content = event.content
        guard content["algorithm"]?.string == Self.olmAlgorithm else {
            throw .unsupportedAlgorithm(content["algorithm"]?.string ?? "")
        }
        guard let senderKey = content["sender_key"]?.string,
              let mine = content["ciphertext"]?[curve25519Key],
              let type = mine["type"]?.int.flatMap(OlmEncrypted.Kind.init(rawValue:)), let body = mine["body"]?.string else {
            throw .badPayload("to-device: нет шифртекста для этого устройства")
        }
        let message = OlmEncrypted(type: type, body: body)
        let plaintext = try await decryptOlm(message, senderKey: senderKey)

        guard let json = try? JSONValue(data: plaintext), let innerType = json["type"]?.string else {
            throw .badPayload("to-device: открытый текст не JSON")
        }
        // Проверки из спецификации: сообщение адресовано нам и отправлено тем, кто указан в событии.
        guard json["sender"]?.string == event.sender, json["recipient"]?.string == userID,
              json["recipient_keys", "ed25519"]?.string == ed25519Key else {
            throw .badPayload("to-device: чужой получатель или отправитель")
        }
        var unsigned: [String: JSONValue] = ["sender_key": .string(senderKey)]
        if let senderEd = json["keys", "ed25519"]?.string { unsigned["sender_ed25519"] = .string(senderEd) }
        if let device = json["sender_device"]?.string { unsigned["sender_device"] = .string(device) }
        return Event(type: innerType, sender: event.sender, content: json["content"] ?? .object([:]),
                     unsigned: .object(unsigned))
    }

    private func decryptOlm(_ message: OlmEncrypted, senderKey: String) async throws(E2EEError) -> Data {
        let sessions: [OlmSession]
        do { sessions = try await store.olmSessions(senderKey: senderKey) } catch { throw .store("\(error)") }
        for var session in sessions {
            if message.type == .preKey, !session.matches(preKeyBody: message.body) { continue }
            guard let plaintext = try? session.decrypt(message) else { continue }
            do { try await store.saveOlmSession(session) } catch { throw .store("\(error)") }
            return plaintext
        }
        guard message.type == .preKey else { throw .crypto(.badMessage("olm: нет подходящей сессии")) }
        do {
            let (session, plaintext) = try account.inboundSession(theirIdentityKey: senderKey, preKeyBody: message.body)
            try await saveAccount()
            do { try await store.saveOlmSession(session) } catch { throw E2EEError.store("\(error)") }
            // Одноразовый ключ израсходован: сервер узнает об этом и пришлёт счётчик в /sync.
            return plaintext
        } catch let error as CryptoError {
            throw .crypto(error)
        } catch let error as E2EEError {
            throw error
        } catch {
            throw .store("\(error)")
        }
    }

    private func acceptRoomKey(_ event: Event) async throws(E2EEError) {
        let content = event.content
        guard content["algorithm"]?.string == Self.megolmAlgorithm, let roomID = content["room_id"]?.string,
              let sessionKey = content["session_key"]?.string,
              let senderKey = event.unsigned?["sender_key"]?.string else { throw .badPayload("m.room_key") }
        let claimed = event.unsigned?["sender_ed25519"]?.string
        let session: MegolmInboundSession
        do { session = try MegolmInboundSession(sessionKey: sessionKey) } catch { throw .crypto(error) }
        guard content["session_id"]?.string == session.sessionID else { throw .badPayload("m.room_key: session_id") }
        do {
            try await store.saveMegolmSession(session, roomID: roomID, senderKey: senderKey, claimedEd25519: claimed)
        } catch {
            throw .store("\(error)")
        }
        await settleKeyRequest(sessionID: session.sessionID, senderKey: senderKey)
    }

    // MARK: Комнаты

    /// Расшифровка `m.room.encrypted` в комнате. Возвращает событие с настоящим типом и содержимым.
    public func decrypt(_ event: Event, roomID: String) async throws(E2EEError) -> DecryptedEvent {
        let content = event.content
        guard content["algorithm"]?.string == Self.megolmAlgorithm else {
            throw .unsupportedAlgorithm(content["algorithm"]?.string ?? "")
        }
        guard let sessionID = content["session_id"]?.string, let ciphertext = content["ciphertext"]?.string else {
            throw .badPayload("m.room.encrypted: нет session_id или ciphertext")
        }
        let stored: StoredMegolmSession?
        do {
            if let senderKey = content["sender_key"]?.string {
                stored = try await store.megolmSession(senderKey: senderKey, sessionID: sessionID)
            } else {
                stored = try await store.megolmSession(sessionID: sessionID)
            }
        } catch {
            throw .store("\(error)")
        }
        guard let stored, stored.roomID == roomID else {
            if let withheld = try? await store.withheld(sessionID: sessionID, senderKey: content["sender_key"]?.string) {
                throw .withheld(code: withheld.code, reason: withheld.reason)
            }
            throw .missingSession(sessionID: sessionID)
        }
        let result: (plaintext: Data, messageIndex: UInt32)
        do { result = try stored.session.decrypt(ciphertext) } catch { throw .crypto(error) }
        if let eventID = event.eventID {
            let fresh: Bool
            do {
                fresh = try await store.markMegolmIndex(sessionID: sessionID, index: result.messageIndex, eventID: eventID)
            } catch {
                throw .store("\(error)")
            }
            guard fresh else { throw .replay }
        }
        guard let json = try? JSONValue(data: result.plaintext), let type = json["type"]?.string else {
            throw .badPayload("megolm: открытый текст не JSON")
        }
        guard json["room_id"]?.string == roomID else { throw .badPayload("megolm: другая комната") }
        let decrypted = Event(eventID: event.eventID, type: type, sender: event.sender,
                              originServerTS: event.originServerTS, stateKey: event.stateKey,
                              content: json["content"] ?? .object([:]), unsigned: event.unsigned, roomID: roomID)
        return DecryptedEvent(event: decrypted, senderKey: stored.senderKey, sessionID: sessionID,
                              messageIndex: result.messageIndex, isVerifiedSession: stored.session.isVerified)
    }

    public func megolmSessionCount() async -> Int {
        (try? await store.megolmSessionCount()) ?? 0
    }

    // MARK: Бэкап ключей

    /// Ключ SSSS по recovery-коду: проверяется по описанию ключа по умолчанию в account data.
    public func secretStorageKey(recoveryKey: String) async throws(E2EEError) -> (id: String, key: Data) {
        let key: Data
        do { key = try RecoveryKey.decode(recoveryKey) } catch { throw .wrongRecoveryKey }
        let keyID: String
        let description: JSONValue
        do {
            let defaultKey = try await client.accountData(userID: userID, type: "m.secret_storage.default_key")
            guard let id = defaultKey["key"]?.string else { throw E2EEError.noBackup }
            keyID = id
            description = try await client.accountData(userID: userID, type: "m.secret_storage.key.\(id)")
        } catch let error as MatrixError {
            throw error.errcode == "M_NOT_FOUND" ? .noBackup : .server(error)
        } catch {
            throw .noBackup
        }
        guard description["algorithm"]?.string == "m.secret_storage.v1.aes-hmac-sha2" else {
            throw .unsupportedAlgorithm(description["algorithm"]?.string ?? "")
        }
        if let iv = description["iv"]?.string, let mac = description["mac"]?.string {
            guard SecretStorage.check(key: key, iv: iv, mac: mac) else { throw .wrongRecoveryKey }
        }
        return (keyID, key)
    }

    /// Секрет из SSSS (`m.megolm_backup.v1`, `m.cross_signing.self_signing` …) как строка.
    public func secret(_ name: String, keyID: String, key: Data) async throws(E2EEError) -> String {
        let json: JSONValue
        do { json = try await client.accountData(userID: userID, type: name) } catch { throw .server(error) }
        guard let sealed = json["encrypted"]?[keyID], let iv = sealed["iv"]?.string,
              let ciphertext = sealed["ciphertext"]?.string, let mac = sealed["mac"]?.string else {
            throw .badPayload("\(name): нет записи для ключа \(keyID)")
        }
        let plaintext: Data
        do {
            plaintext = try SecretStorage.decrypt(SecretStorageCiphertext(iv: iv, ciphertext: ciphertext, mac: mac),
                                                  name: name, key: key)
        } catch {
            throw error == .badMAC ? .wrongRecoveryKey : .crypto(error)
        }
        return String(decoding: plaintext, as: UTF8.self)
    }

    /// Восстановить ключи комнат из бэкапа на сервере по recovery-коду. Возвращает (новых, всего в бэкапе).
    @discardableResult
    public func restoreBackup(recoveryKey: String) async throws(E2EEError) -> (imported: Int, total: Int) {
        let ssss = try await secretStorageKey(recoveryKey: recoveryKey)
        let privateKey = try await secret("m.megolm_backup.v1", keyID: ssss.id, key: ssss.key)
        let backupKey: BackupKey
        do { backupKey = try BackupKey(privateKey: try Base64.decode(privateKey)) } catch { throw .crypto(error) }

        let version: BackupVersion
        do {
            guard let current = try await client.backupVersion() else { throw E2EEError.noBackup }
            version = current
        } catch let error as MatrixError {
            throw .server(error)
        } catch {
            throw .noBackup
        }
        guard version.algorithm == Self.backupAlgorithm else { throw .unsupportedAlgorithm(version.algorithm) }
        guard version.publicKey == backupKey.publicKeyBase64 else { throw .wrongRecoveryKey }
        do {
            // Другая версия бэкапа: в ней нет того, что мы выгружали в прежнюю.
            if try await store.meta("e2ee_backup_version") != version.version { try await store.resetMegolmBackedUp() }
            try await store.setCryptoBlob("backup_key", backupKey.keyPair.rawRepresentation)
            try await store.setMeta("e2ee_backup_version", version.version)
        } catch {
            throw .store("\(error)")
        }

        let rooms: [String: [String: JSONValue]]
        do { rooms = try await client.backupKeys(version: version.version) } catch { throw .server(error) }
        var total = 0
        var imported = 0
        for (roomID, sessions) in rooms {
            for (sessionID, entry) in sessions {
                total += 1
                guard let data = entry["session_data"], let ephemeral = data["ephemeral"]?.string,
                      let ciphertext = data["ciphertext"]?.string, let mac = data["mac"]?.string,
                      let plaintext = try? backupKey.decrypt(BackupSessionData(ephemeral: ephemeral, ciphertext: ciphertext, mac: mac)),
                      let json = try? JSONValue(data: plaintext),
                      json["algorithm"]?.string == Self.megolmAlgorithm,
                      let sessionKey = json["session_key"]?.string, let senderKey = json["sender_key"]?.string else { continue }
                guard let session = try? Self.parseExported(sessionKey, sessionID: sessionID) else { continue }
                do {
                    if try await store.saveMegolmSession(session, roomID: roomID, senderKey: senderKey, backedUp: true,
                                                         claimedEd25519: json["sender_claimed_keys", "ed25519"]?.string) {
                        imported += 1
                    }
                } catch {
                    throw .store("\(error)")
                }
            }
        }
        return (imported, total)
    }

    private static func parseExported(_ exported: String, sessionID: String?) throws(E2EEError) -> MegolmInboundSession {
        let session: MegolmInboundSession
        do { session = try MegolmInboundSession(exportedKey: exported) } catch { throw .crypto(error) }
        if let sessionID, sessionID != session.sessionID { throw .badPayload("session_id не совпал с ключом") }
        return session
    }
}
