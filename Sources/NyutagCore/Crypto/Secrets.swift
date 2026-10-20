// Нютаг. Обмен секретами между своими устройствами (`m.secret.request` / `m.secret.send`): новое устройство после
// проверки по эмодзи получает от старого ключи кросс-подписи и ключ бэкапа без recovery-кода. Секреты отдаём только
// своему подтверждённому устройству и только по Olm; принимаем только на свой запрос и от подтверждённого устройства.

import Foundation
import NyutagCrypto

extension CryptoMachine {
    static let secretRequestType = "m.secret.request"
    static let secretSendType = "m.secret.send"
    static let backupSecretName = "m.megolm_backup.v1"
    static var sharedSecretNames: [String] { CrossSigningKind.allCases.map(\.secretName) + [backupSecretName] }

    // MARK: Локальное доверие

    /// Устройство подтверждено вручную на этом устройстве (по эмодзи), без подписи кросс-подписью.
    func trustLocally(_ device: DeviceInfo) async throws(E2EEError) {
        var trusted = await locallyTrusted()
        trusted.insert("\(device.userID)|\(device.deviceID)|\(device.ed25519Key)")
        let list = trusted.sorted()
        try await storing { try await store.setCryptoBlob("trusted_devices", try JSONEncoder().encode(list)) }
    }

    func locallyTrusted() async -> Set<String> {
        guard let blob = try? await store.cryptoBlob("trusted_devices"),
              let list = try? JSONDecoder().decode([String].self, from: blob) else { return [] }
        return Set(list)
    }

    func isLocallyTrusted(_ device: DeviceInfo) async -> Bool {
        await locallyTrusted().contains("\(device.userID)|\(device.deviceID)|\(device.ed25519Key)")
    }

    // MARK: Запрос

    /// Попросить у своего подтверждённого устройства ключи кросс-подписи и ключ бэкапа.
    func requestSecrets(from device: DeviceInfo) async throws(E2EEError) {
        // Один секрет на событие: у sendToDevice одно содержимое на устройство.
        for name in Self.sharedSecretNames {
            let requestID = TransactionID.make()
            secretRequests[requestID] = (name, device.deviceID)
            let content: JSONValue = ["name": .string(name), "action": "request",
                                      "requesting_device_id": .string(deviceID), "request_id": .string(requestID)]
            do {
                try await client.sendToDevice(type: Self.secretRequestType, messages: [userID: [device.deviceID: content]])
            } catch {
                throw .server(error)
            }
        }
    }

    /// Пришёл секрет: принять, если просили и прислало то устройство, у которого просили.
    func acceptSecret(_ event: Event) async throws(E2EEError) {
        guard event.sender == userID, let from = event.unsigned?["sender_key"]?.string,
              let requestID = event.content["request_id"]?.string, let secret = event.content["secret"]?.string,
              let request = secretRequests[requestID] else { return }
        let name = request.name
        guard let device = try await devices(for: [userID]).first(where: { $0.deviceID == request.deviceID }),
              device.curve25519Key == from, await isVerified(device) else { return }
        secretRequests[requestID] = nil
        if name == Self.backupSecretName {
            let (backupKey, version) = try await adoptBackupKey(secret)
            _ = try await importBackup(backupKey, version: version)
            return
        }
        guard let kind = CrossSigningKind.allCases.first(where: { $0.secretName == name }) else { return }
        do { receivedCrossSigning[kind] = try Ed25519KeyPair(rawRepresentation: try Base64.decode(secret)) } catch {
            throw .crypto(error)
        }
        try await adoptReceivedCrossSigning()
    }

    /// Мастер и самоподпись пришли: сверить с сервером и сохранить. Ключа подписи пользователей у старого устройства
    /// может не быть; если он придёт позже, ключи сохраняются ещё раз.
    private func adoptReceivedCrossSigning() async throws(E2EEError) {
        guard let master = receivedCrossSigning[.master], let selfSigning = receivedCrossSigning[.selfSigning] else { return }
        let response: JSONValue
        do { response = try await client.queryKeys(userIDs: [userID]) } catch { throw .server(error) }
        func matches(_ field: String, _ usage: String, _ key: Ed25519KeyPair) -> Bool {
            response[field, userID].flatMap { Self.crossSigningPublicKey($0, userID: userID, usage: usage) }
                == key.publicKeyBase64
        }
        guard matches("master_keys", "master", master), matches("self_signing_keys", "self_signing", selfSigning)
        else { throw .badPayload("присланные ключи кросс-подписи не совпадают с ключами на сервере") }
        var userSigning = receivedCrossSigning[.userSigning]
        if let key = userSigning, !matches("user_signing_keys", "user_signing", key) { userSigning = nil }
        try await adoptCrossSigning(master: master, selfSigning: selfSigning, userSigning: userSigning)
    }

    // MARK: Ответ

    /// Отдать секрет своему подтверждённому устройству. Возвращает, ушёл ли секрет.
    @discardableResult
    func answerSecretRequest(_ event: Event) async throws(E2EEError) -> Bool {
        let content = event.content
        guard event.sender == userID, content["action"]?.string == "request",
              let name = content["name"]?.string, Self.sharedSecretNames.contains(name),
              let requester = content["requesting_device_id"]?.string, requester != deviceID,
              let requestID = content["request_id"]?.string else { return false }
        guard let device = try await ownDevice(requester), await isVerified(device) else { return false }
        let secret: String
        if name == Self.backupSecretName {
            guard let raw = try await storing({ try await store.cryptoBlob("backup_key") }) else { return false }
            secret = Base64.encodeUnpadded(raw)
        } else {
            guard let kind = CrossSigningKind.allCases.first(where: { $0.secretName == name }),
                  let key = try await ownCrossSigningKey(kind) else { return false }
            secret = Base64.encodeUnpadded(key.rawRepresentation)
        }
        let sent = try await sendEncryptedToDevice(type: Self.secretSendType,
                                                   content: ["request_id": .string(requestID), "secret": .string(secret)],
                                                   to: [device])
        return !sent.isEmpty
    }
}
