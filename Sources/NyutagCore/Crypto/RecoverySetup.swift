// Нютаг. Включение восстановления с нуля: ключи кросс-подписи, бэкап ключей комнат, хранилище секретов SSSS
// и recovery-код. Тот же вызов меняет recovery-код: бэкап остаётся прежним, секреты перешифровываются новым ключом.

import Foundation
import NyutagCrypto

extension CryptoMachine {
    static let secretStorageAlgorithm = "m.secret_storage.v1.aes-hmac-sha2"
    /// Как у Element: на телефоне доли секунды, перебор паролей по утёкшей account data дорогой.
    public static let passphraseIterations = 500_000

    /// Включить восстановление и вернуть новый recovery-код (показать человеку один раз).
    /// Ключи кросс-подписи заводятся, только если на сервере их ещё нет. Если они есть, а у этого устройства закрытых
    /// ключей нет, нужно сначала подтвердить устройство или ввести старый код; `resetIdentity` заводит новые ключи,
    /// и все прежние подтверждения сбрасываются.
    /// `passphrase`: ключ хранилища выводится из фразы (PBKDF2), и открыть его можно этой же фразой, без кода.
    /// Нютаг передаёт сюда пароль аккаунта: вход паролем на новом устройстве сразу поднимает историю.
    public func enableRecovery(password: String?, resetIdentity: Bool = false, passphrase: String? = nil,
                               iterations: Int = passphraseIterations) async throws(E2EEError) -> String {
        try await ensureCrossSigning(password: password, resetIdentity: resetIdentity)
        let backupKey = try await ensureBackup()

        let key: Data
        var description: [String: JSONValue] = ["algorithm": .string(Self.secretStorageAlgorithm)]
        if let passphrase {
            let salt = Self.secretStorageKeyID()
            do { key = try RecoveryKey.fromPassphrase(passphrase, salt: salt, iterations: iterations) } catch {
                throw .crypto(error)
            }
            description["passphrase"] = ["algorithm": "m.pbkdf2", "salt": .string(salt), "iterations": .int(iterations)]
        } else {
            key = Random.bytes(32)
        }
        let keyID = Self.secretStorageKeyID()
        let check: SecretStorageCiphertext
        do { check = try SecretStorage.encrypt(Data(count: 32), name: "", key: key) } catch { throw .crypto(error) }
        description["iv"] = .string(check.iv)
        description["mac"] = .string(check.mac)
        try await putAccountData("m.secret_storage.key.\(keyID)", .object(description))
        var secrets = [Self.backupSecretName: Base64.encodeUnpadded(backupKey.keyPair.rawRepresentation)]
        for kind in CrossSigningKind.allCases {
            if let pair = try await ownCrossSigningKey(kind) { secrets[kind.secretName] = Base64.encodeUnpadded(pair.rawRepresentation) }
        }
        for (name, secret) in secrets.sorted(by: { $0.key < $1.key }) {
            let sealed: SecretStorageCiphertext
            do { sealed = try SecretStorage.encrypt(Data(secret.utf8), name: name, key: key) } catch { throw .crypto(error) }
            try await putAccountData(name, ["encrypted": [keyID: ["iv": .string(sealed.iv),
                                                                  "ciphertext": .string(sealed.ciphertext),
                                                                  "mac": .string(sealed.mac)]]])
        }
        // Ключ по умолчанию меняем последним: до этого старый код продолжает работать.
        try await putAccountData("m.secret_storage.default_key", ["key": .string(keyID)])
        try await uploadRoomKeysToBackup()
        return RecoveryKey.encode(key)
    }

    /// Закрытые ключи кросс-подписи на устройстве и совпадают с серверными; иначе завести новые, если можно.
    private func ensureCrossSigning(password: String?, resetIdentity: Bool) async throws(E2EEError) {
        let response: JSONValue
        do { response = try await client.queryKeys(userIDs: [userID]) } catch { throw .server(error) }
        let serverMaster = response["master_keys", userID].flatMap {
            Self.crossSigningPublicKey($0, userID: userID, usage: "master")
        }
        if serverMaster == nil || resetIdentity {
            try await bootstrapCrossSigning(password: password)
            return
        }
        guard let master = try await ownCrossSigningKey(.master), master.publicKeyBase64 == serverMaster,
              try await ownCrossSigningKey(.selfSigning) != nil else {
            throw .badPayload("у этого устройства нет ключей кросс-подписи: подтвердите его или введите прежний код")
        }
    }

    /// Ключ бэкапа, подходящий к текущей версии на сервере; если такого нет, заводится новая версия.
    private func ensureBackup() async throws(E2EEError) -> BackupKey {
        if let raw = try await storing({ try await store.cryptoBlob("backup_key") }),
           let local = try? BackupKey(privateKey: raw),
           let current = try? await client.backupVersion(), current.algorithm == Self.backupAlgorithm,
           current.publicKey == local.publicKeyBase64 {
            _ = try await adoptBackupKey(Base64.encodeUnpadded(raw))
            return local
        }
        let backupKey = BackupKey()
        var authData = sign(["public_key": .string(backupKey.publicKeyBase64)])
        if let master = try await ownCrossSigningKey(.master) {
            authData = Self.signed(authData, userID: userID, keyID: master.publicKeyBase64, with: master)
        }
        do {
            _ = try await client.createBackupVersion(algorithm: Self.backupAlgorithm, authData: authData)
        } catch {
            throw .server(error)
        }
        _ = try await adoptBackupKey(Base64.encodeUnpadded(backupKey.keyPair.rawRepresentation))
        return backupKey
    }

    private func putAccountData(_ type: String, _ content: JSONValue) async throws(E2EEError) {
        do { try await client.setAccountData(userID: userID, type: type, content: content) } catch { throw .server(error) }
    }

    /// Идентификатор ключа SSSS: 32 буквы и цифры, как у Element.
    static func secretStorageKeyID() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return String(Random.bytes(32).map { alphabet[Int($0) % alphabet.count] })
    }
}
