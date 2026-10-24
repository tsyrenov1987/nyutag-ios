// Нютаг. История по паролю аккаунта: хранилище секретов SSSS заперто ключом из пароля (PBKDF2), поэтому вход паролем
// на новом устройстве сразу поднимает ключи кросс-подписи и бэкап ключей комнат. Отдельного recovery-кода человек не видит.

import Foundation

public enum PasswordUnlockOutcome: Sendable, Equatable {
    /// Хранилище открыто паролем: устройство подписано, из бэкапа поднято `imported` ключей комнат.
    case opened(imported: Int)
    /// Хранилища не было: завели его под этим паролем (и ключи кросс-подписи, если их не было на сервере).
    case created
    /// Хранилище было заперто не этим паролем (старый случайный ключ, пароль сменён через почту) или личность есть
    /// без хранилища и без ключей на устройстве: завели новую личность и хранилище под паролем. Переписка под
    /// прежним ключом не читается, дальше любой вход паролем поднимает историю.
    case reset
}

extension CryptoMachine {
    /// Открыть или завести хранилище секретов паролем аккаунта. Вызывать после входа, пароль уже проверен сервером.
    public func unlockWithPassword(_ password: String,
                                   iterations: Int = passphraseIterations) async throws(E2EEError) -> PasswordUnlockOutcome {
        do {
            _ = try await defaultSecretStorageKey()
        } catch .noBackup {
            let fresh = try await canStartIdentity()
            _ = try await enableRecovery(password: password, resetIdentity: !fresh, passphrase: password,
                                         iterations: iterations)
            return fresh ? .created : .reset
        }
        let ssss: (id: String, key: Data)
        do {
            ssss = try await secretStorageKey(passphrase: password)
        } catch .wrongRecoveryKey {
            // Владелец 23.10: ключ восстановления не спрашиваем никогда, вход паролем всегда сохраняет историю.
            _ = try await enableRecovery(password: password, resetIdentity: true, passphrase: password,
                                         iterations: iterations)
            return .reset
        }
        try await importCrossSigning(ssss: ssss)
        return .opened(imported: try await restoreBackupIfAny(ssss: ssss))
    }

    /// Хранилище заперто старым кодом: открыть его кодом один раз и перезапереть паролем. Возвращает число ключей из бэкапа.
    public func relockWithPassword(recoveryKey: String, password: String,
                                   iterations: Int = passphraseIterations) async throws(E2EEError) -> Int {
        let ssss = try await secretStorageKey(recoveryKey: recoveryKey)
        try await importCrossSigning(ssss: ssss)
        let imported = try await restoreBackupIfAny(ssss: ssss)
        _ = try await enableRecovery(password: password, passphrase: password, iterations: iterations)
        return imported
    }

    /// Личность можно завести или переиспользовать: на сервере её нет, либо её закрытые ключи уже на этом устройстве.
    private func canStartIdentity() async throws(E2EEError) -> Bool {
        let response: JSONValue
        do { response = try await client.queryKeys(userIDs: [userID]) } catch { throw .server(error) }
        guard let serverMaster = response["master_keys", userID].flatMap({
            Self.crossSigningPublicKey($0, userID: userID, usage: "master")
        }) else { return true }
        let master = try await ownCrossSigningKey(.master)
        let selfSigning = try await ownCrossSigningKey(.selfSigning)
        return master?.publicKeyBase64 == serverMaster && selfSigning != nil
    }

    /// Бэкапа ещё нет (или секрет не сохранён) — это не ошибка входа: ключей просто ноль.
    private func restoreBackupIfAny(ssss: (id: String, key: Data)) async throws(E2EEError) -> Int {
        do {
            return try await restoreBackup(ssss: ssss).imported
        } catch .noBackup {
            return 0
        }
    }
}
