// Нютаг. Кросс-подпись: мастер-ключ пользователя, ключ самоподписи (подписывает свои устройства) и ключ подписи
// пользователей (подписывает чужие мастер-ключи). Устройство подтверждено, если его подписал ключ самоподписи
// владельца, а мастер-ключ владельца подтверждён нами.

import Foundation
import NyutagCrypto

extension CryptoMachine {
    enum CrossSigningKind: String, CaseIterable {
        case master
        case selfSigning = "self_signing"
        case userSigning = "user_signing"

        var secretName: String { "m.cross_signing.\(rawValue)" }
        var blobName: String { "xsign_\(rawValue)" }
    }

    /// Подписать объект произвольным ключом Ed25519 (`keyID` — часть после `ed25519:`).
    static func signed(_ object: JSONValue, userID: String, keyID: String, with key: Ed25519KeyPair) -> JSONValue {
        guard case .object(var fields) = object else { return object }
        let unsigned = fields.removeValue(forKey: "unsigned")
        var signatures = fields.removeValue(forKey: "signatures")?.object ?? [:]
        let signature = Base64.encodeUnpadded(key.sign(Data(JSONValue.object(fields).canonicalJSON().utf8)))
        var mine = signatures[userID]?.object ?? [:]
        mine["ed25519:\(keyID)"] = .string(signature)
        signatures[userID] = .object(mine)
        fields["signatures"] = .object(signatures)
        if let unsigned { fields["unsigned"] = unsigned }
        return .object(fields)
    }

    /// Открытый ключ из объекта ключа кросс-подписи, если он правильно оформлен.
    static func crossSigningPublicKey(_ json: JSONValue, userID: String, usage: String) -> String? {
        guard json["user_id"]?.string == userID, json["usage"]?.array?.contains(.string(usage)) == true,
              let keys = json["keys"]?.object, keys.count == 1, let (keyID, value) = keys.first,
              let key = value.string, keyID == "ed25519:\(key)" else { return nil }
        return key
    }

    static func crossSigningObject(userID: String, usage: CrossSigningKind, key: Ed25519KeyPair) -> JSONValue {
        ["user_id": .string(userID), "usage": [.string(usage.rawValue)],
         "keys": .object(["ed25519:\(key.publicKeyBase64)": .string(key.publicKeyBase64)])]
    }

    func ownCrossSigningKey(_ kind: CrossSigningKind) async throws(E2EEError) -> Ed25519KeyPair? {
        guard let raw = try await storing({ try await store.cryptoBlob(kind.blobName) }) else { return nil }
        do { return try Ed25519KeyPair(rawRepresentation: raw) } catch { throw .crypto(error) }
    }

    /// Ключи кросс-подписи пользователя из ответа `/keys/query` и доверяем ли мы его мастер-ключу.
    func crossSigningIdentity(_ user: String, in response: JSONValue) async throws(E2EEError) -> CrossSigningIdentity? {
        guard let master = response["master_keys", user],
              let masterKey = Self.crossSigningPublicKey(master, userID: user, usage: "master") else { return nil }
        var selfSigningKey: String?
        if let selfSigning = response["self_signing_keys", user],
           let key = Self.crossSigningPublicKey(selfSigning, userID: user, usage: "self_signing"),
           Self.verifySignature(selfSigning, userID: user, keyID: masterKey, publicKey: masterKey) {
            selfSigningKey = key
        }
        let verified: Bool
        if user == userID {
            verified = try await ownCrossSigningKey(.master)?.publicKeyBase64 == masterKey
        } else if let userSigning = try await ownCrossSigningKey(.userSigning)?.publicKeyBase64 {
            verified = Self.verifySignature(master, userID: userID, keyID: userSigning, publicKey: userSigning)
        } else {
            verified = false
        }
        return CrossSigningIdentity(userID: user, masterKey: masterKey, selfSigningKey: selfSigningKey, verified: verified)
    }

    /// Устройство подтверждено: его подписал ключ самоподписи владельца, а мастер-ключ владельца подтверждён.
    public func isVerified(_ device: DeviceInfo) async -> Bool {
        guard device.crossSigned else { return false }
        return (try? await store.crossSigning(userID: device.userID))?.verified == true
    }

    /// Ключи кросс-подписи пользователя, как их видит это устройство.
    public func crossSigningIdentity(userID: String) async -> CrossSigningIdentity? {
        try? await store.crossSigning(userID: userID)
    }

    /// Есть ли на этом устройстве закрытые ключи кросс-подписи.
    public var hasCrossSigningKeys: Bool {
        get async { (try? await store.cryptoBlob(CrossSigningKind.selfSigning.blobName)) != nil }
    }

    // MARK: Ключи из SSSS

    /// Поднять ключи кросс-подписи из SSSS по recovery-коду и подписать ими это устройство.
    /// Ключи на сервере должны совпасть с сохранёнными: иначе сервер подменил личность.
    public func importCrossSigning(recoveryKey: String) async throws(E2EEError) {
        let ssss = try await secretStorageKey(recoveryKey: recoveryKey)
        var pairs: [CrossSigningKind: Ed25519KeyPair] = [:]
        for kind in CrossSigningKind.allCases {
            let secret: String
            do {
                secret = try await self.secret(kind.secretName, keyID: ssss.id, key: ssss.key)
            } catch {
                // Ключа подписи пользователей может не быть (старые аккаунты); без мастера и самоподписи — нельзя.
                if kind == .userSigning, case .server = error { continue }
                if kind == .userSigning, case .badPayload = error { continue }
                throw error
            }
            do { pairs[kind] = try Ed25519KeyPair(rawRepresentation: try Base64.decode(secret)) } catch {
                throw .crypto(error)
            }
        }
        guard let master = pairs[.master], let selfSigning = pairs[.selfSigning] else { throw .noBackup }
        let response: JSONValue
        do { response = try await client.queryKeys(userIDs: [userID]) } catch { throw .server(error) }
        let serverMaster = response["master_keys", userID].flatMap {
            Self.crossSigningPublicKey($0, userID: userID, usage: "master")
        }
        let serverSelf = response["self_signing_keys", userID].flatMap {
            Self.crossSigningPublicKey($0, userID: userID, usage: "self_signing")
        }
        guard serverMaster == master.publicKeyBase64, serverSelf == selfSigning.publicKeyBase64 else {
            throw .badPayload("ключи кросс-подписи на сервере не совпадают с сохранёнными в SSSS")
        }
        try await adoptCrossSigning(master: master, selfSigning: selfSigning, userSigning: pairs[.userSigning])
    }

    /// Сохранить закрытые ключи кросс-подписи на устройстве и подписать им само устройство.
    func adoptCrossSigning(master: Ed25519KeyPair, selfSigning: Ed25519KeyPair,
                           userSigning: Ed25519KeyPair?) async throws(E2EEError) {
        try await storing {
            try await store.setCryptoBlob(CrossSigningKind.master.blobName, master.rawRepresentation)
            try await store.setCryptoBlob(CrossSigningKind.selfSigning.blobName, selfSigning.rawRepresentation)
            try await store.setCryptoBlob(CrossSigningKind.userSigning.blobName, userSigning?.rawRepresentation)
        }
        try await signOwnDevice()
        try await storing { try await store.markAllDeviceListsChanged() }
    }

    /// Подписать ключи этого устройства ключом самоподписи и отправить подпись на сервер.
    public func signOwnDevice() async throws(E2EEError) {
        guard let selfSigning = try await ownCrossSigningKey(.selfSigning) else { throw .noBackup }
        var keys = deviceKeys()
        if case .object(var fields) = keys {
            fields["signatures"] = nil
            keys = .object(fields)
        }
        let signed = Self.signed(keys, userID: userID, keyID: selfSigning.publicKeyBase64, with: selfSigning)
        let failures: JSONValue
        do { failures = try await client.uploadSignatures([userID: [deviceID: signed]]) } catch { throw .server(error) }
        if let failure = failures[userID, deviceID] {
            throw .badPayload("подпись устройства отклонена: \(failure["errcode"]?.string ?? "")")
        }
    }

    // MARK: С нуля

    /// Завести ключи кросс-подписи для аккаунта, где их ещё нет. Сервер обычно просит подтвердить паролем.
    /// ⚠️ Заменяет прежнюю личность: все подтверждения устройств и собеседников сбрасываются.
    public func bootstrapCrossSigning(password: String?) async throws(E2EEError) {
        let master = Ed25519KeyPair()
        let selfSigning = Ed25519KeyPair()
        let userSigning = Ed25519KeyPair()
        let masterObject = sign(Self.crossSigningObject(userID: userID, usage: .master, key: master))
        let selfObject = Self.signed(Self.crossSigningObject(userID: userID, usage: .selfSigning, key: selfSigning),
                                     userID: userID, keyID: master.publicKeyBase64, with: master)
        let userObject = Self.signed(Self.crossSigningObject(userID: userID, usage: .userSigning, key: userSigning),
                                     userID: userID, keyID: master.publicKeyBase64, with: master)
        do {
            try await client.uploadCrossSigningKeys(master: masterObject, selfSigning: selfObject, userSigning: userObject)
        } catch {
            guard let session = error.uiaSession, let password else { throw .server(error) }
            let auth: JSONValue = [
                "type": "m.login.password", "identifier": ["type": "m.id.user", "user": .string(userID)],
                "password": .string(password), "session": .string(session),
            ]
            do {
                try await client.uploadCrossSigningKeys(master: masterObject, selfSigning: selfObject,
                                                        userSigning: userObject, auth: auth)
            } catch {
                throw .server(error)
            }
        }
        try await adoptCrossSigning(master: master, selfSigning: selfSigning, userSigning: userSigning)
    }
}
