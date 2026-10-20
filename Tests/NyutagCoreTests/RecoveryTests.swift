import Foundation
@testable import NyutagCore
import NyutagCrypto
import Testing

/// Включение восстановления с нуля: кросс-подпись, бэкап, SSSS и recovery-код на поддельном сервере.
@Suite struct RecoveryTests {
    static let room = OutboundTests.room
    static let alice = "@alice:nyutag.chat"
    static let bob = "@bob:nyutag.chat"

    typealias Device = OutboundTests.Device

    func device(_ server: FakeHomeserver, _ user: String, _ id: String) async throws -> Device {
        try await OutboundTests().device(server, user, id)
    }

    func read(_ server: FakeHomeserver, _ device: Device) async -> [String?] {
        await OutboundTests().read(server, device)
    }

    /// Подпись `auth_data` ключом `ed25519:<keyID>` сходится с открытым ключом.
    func signatureValid(_ object: JSONValue, user: String, keyID: String, publicKey: String) throws -> Bool {
        guard case .object(var fields) = object,
              let signature = object["signatures", user, "ed25519:\(keyID)"]?.string else { return false }
        fields["signatures"] = nil
        return Ed25519KeyPair.verify(signature: try Base64.decode(signature), message: Data(JSONValue.object(fields).canonicalJSON().utf8),
                              publicKey: try Base64.decode(publicKey))
    }

    @Test func recoveryFromScratchOpensHistoryOnNewDevice() async throws {
        let server = FakeHomeserver()
        server.requirePassword = "pw"
        let alice = try await device(server, Self.alice, "A1")
        let bob = try await device(server, Self.bob, "B1")
        server.setMembers([Self.alice, Self.bob], roomID: Self.room)
        try await bob.machine.sendEncrypted(roomID: Self.room, type: EventType.message,
                                            content: OutboundTests().text("до бэкапа"))
        #expect(await read(server, alice) == ["до бэкапа"])

        // Без пароля сервер не даст завести кросс-подпись.
        await #expect(throws: E2EEError.self) { try await alice.machine.enableRecovery(password: nil) }
        let code = try await alice.machine.enableRecovery(password: "pw")
        #expect(code.hasPrefix("Es"))
        let master = try #require(server.crossSigningKey(user: Self.alice, usage: "master").flatMap {
            CryptoMachine.crossSigningPublicKey($0, userID: Self.alice, usage: "master")
        })
        #expect(server.backup[Self.room]?.count == 1)
        let authData = try #require(server.backupAuthData)
        #expect(try signatureValid(authData, user: Self.alice, keyID: "A1", publicKey: alice.machine.ed25519Key))
        #expect(try signatureValid(authData, user: Self.alice, keyID: master, publicKey: master))
        let keyID = try #require(server.accountDataContent(user: Self.alice, type: "m.secret_storage.default_key")?["key"]?.string)
        for name in CryptoMachine.sharedSecretNames {
            #expect(server.accountDataContent(user: Self.alice, type: name)?["encrypted", keyID] != nil, "\(name)")
        }

        // Новое устройство по коду: ключи кросс-подписи, подпись себя, история комнаты.
        let fresh = try await device(server, Self.alice, "A2")
        #expect(await read(server, fresh) == [nil])
        try await fresh.machine.importCrossSigning(recoveryKey: code)
        let restored = try await fresh.machine.restoreBackup(recoveryKey: code)
        #expect(restored.imported == 1)
        #expect(await read(server, fresh) == ["до бэкапа"])
        #expect(try await alice.machine.devices(for: [Self.alice]).first { $0.deviceID == "A2" }?.crossSigned == true)
        // Ключ бэкапа у нового устройства тот же: его собственная сессия выгружается в ту же версию.
        try await fresh.machine.sendEncrypted(roomID: Self.room, type: EventType.message,
                                              content: OutboundTests().text("после"))
        #expect(try await fresh.machine.uploadRoomKeysToBackup() == 1)
        #expect(server.backup[Self.room]?.count == 2)
    }

    @Test func newCodeReplacesOldAndKeepsBackup() async throws {
        let server = FakeHomeserver()
        let alice = try await device(server, Self.alice, "A1")
        let bob = try await device(server, Self.bob, "B1")
        server.setMembers([Self.alice, Self.bob], roomID: Self.room)
        try await bob.machine.sendEncrypted(roomID: Self.room, type: EventType.message,
                                            content: OutboundTests().text("x"))
        _ = await read(server, alice)
        let first = try await alice.machine.enableRecovery(password: nil)
        let master = server.crossSigningKey(user: Self.alice, usage: "master")
        let version = server.backupVersion

        let second = try await alice.machine.enableRecovery(password: nil)
        #expect(second != first)
        #expect(server.backupVersion == version)
        #expect(server.crossSigningKey(user: Self.alice, usage: "master") == master)
        #expect(server.backup[Self.room]?.count == 1)

        let fresh = try await device(server, Self.alice, "A2")
        await #expect(throws: E2EEError.wrongRecoveryKey) { try await fresh.machine.restoreBackup(recoveryKey: first) }
        #expect(try await fresh.machine.restoreBackup(recoveryKey: second).imported == 1)
    }

    @Test func existingIdentityNeedsKeysOrExplicitReset() async throws {
        let server = FakeHomeserver()
        let old = try await device(server, Self.alice, "A1")
        try await old.machine.bootstrapCrossSigning(password: nil)
        let master = server.crossSigningKey(user: Self.alice, usage: "master")

        // У нового устройства закрытых ключей нет: молча менять личность нельзя.
        let fresh = try await device(server, Self.alice, "A2")
        await #expect(throws: E2EEError.self) { try await fresh.machine.enableRecovery(password: nil) }
        #expect(server.crossSigningKey(user: Self.alice, usage: "master") == master)
        #expect(server.backupAuthData == nil)
        #expect(server.accountDataContent(user: Self.alice, type: "m.secret_storage.default_key") == nil)

        let code = try await fresh.machine.enableRecovery(password: nil, resetIdentity: true)
        #expect(server.crossSigningKey(user: Self.alice, usage: "master") != master)
        let other = try await device(server, Self.alice, "A3")
        try await other.machine.importCrossSigning(recoveryKey: code)
        #expect(try await other.machine.devices(for: [Self.alice]).first { $0.deviceID == "A2" }?.crossSigned == true)
    }

    @Test func staleLocalBackupKeyGetsNewVersion() async throws {
        let server = FakeHomeserver()
        let alice = try await device(server, Self.alice, "A1")
        _ = try await alice.machine.enableRecovery(password: nil)
        #expect(server.backupVersion == "2")
        // Ключ бэкапа на устройстве к версии на сервере не подходит (например, бэкап завели с другого устройства).
        try await alice.machine.store.setCryptoBlob("backup_key", BackupKey().keyPair.rawRepresentation)
        let code = try await alice.machine.enableRecovery(password: nil)
        #expect(server.backupVersion == "3")
        let fresh = try await device(server, Self.alice, "A2")
        _ = try await fresh.machine.restoreBackup(recoveryKey: code)
        let local = try #require(try await fresh.machine.store.cryptoBlob("backup_key"))
        #expect(server.backupAuthData?["public_key"]?.string == (try BackupKey(privateKey: local).publicKeyBase64))
    }
}
