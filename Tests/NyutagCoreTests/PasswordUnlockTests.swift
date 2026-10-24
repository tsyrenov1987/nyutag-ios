import Foundation
@testable import NyutagCore
import NyutagCrypto
import Testing

/// Хранилище секретов под паролем аккаунта: вход паролем на новом устройстве поднимает историю без recovery-кода.
@Suite struct PasswordUnlockTests {
    static let room = OutboundTests.room
    static let alice = "@alice:nyutag.chat"
    static let bob = "@bob:nyutag.chat"
    /// В приложении 500 000; в тестах меньше, чтобы не ждать.
    static let iterations = 1000

    func device(_ server: FakeHomeserver, _ user: String, _ id: String) async throws -> OutboundTests.Device {
        try await OutboundTests().device(server, user, id)
    }

    @Test func firstSignInCreatesThenNewDeviceOpensByPassword() async throws {
        let server = FakeHomeserver()
        server.requirePassword = "пароль-1"
        let alice = try await device(server, Self.alice, "A1")
        let bob = try await device(server, Self.bob, "B1")
        server.setMembers([Self.alice, Self.bob], roomID: Self.room)
        try await bob.machine.sendEncrypted(roomID: Self.room, type: EventType.message,
                                            content: OutboundTests().text("сайн байна"))
        #expect(await OutboundTests().read(server, alice) == ["сайн байна"])

        #expect(try await alice.machine.unlockWithPassword("пароль-1", iterations: Self.iterations) == .created)
        let keyID = try #require(server.accountDataContent(user: Self.alice, type: "m.secret_storage.default_key")?["key"]?.string)
        let description = try #require(server.accountDataContent(user: Self.alice, type: "m.secret_storage.key.\(keyID)"))
        #expect(description["passphrase", "algorithm"]?.string == "m.pbkdf2")
        #expect(description["passphrase", "iterations"]?.int == Self.iterations)

        let fresh = try await device(server, Self.alice, "A2")
        #expect(await OutboundTests().read(server, fresh) == [nil])
        #expect(try await fresh.machine.unlockWithPassword("пароль-1", iterations: Self.iterations) == .opened(imported: 1))
        #expect(await OutboundTests().read(server, fresh) == ["сайн байна"])
        #expect(try await alice.machine.devices(for: [Self.alice]).first { $0.deviceID == "A2" }?.crossSigned == true)
    }

    @Test func identityWithoutStorageIsResetByPassword() async throws {
        let server = FakeHomeserver()
        let old = try await device(server, Self.alice, "A1")
        try await old.machine.bootstrapCrossSigning(password: nil)
        let master = server.crossSigningKey(user: Self.alice, usage: "master")

        let fresh = try await device(server, Self.alice, "A2")
        // Ключей личности на устройстве нет и подтвердить нечем: заводим новую личность под паролем.
        #expect(try await fresh.machine.unlockWithPassword("pw", iterations: Self.iterations) == .reset)
        #expect(server.crossSigningKey(user: Self.alice, usage: "master") != master)
        #expect(server.accountDataContent(user: Self.alice, type: "m.secret_storage.default_key") != nil)
        #expect(try await fresh.machine.unlockWithPassword("pw", iterations: Self.iterations) == .opened(imported: 0))
    }

    @Test func oldRandomCodeIsResetAndPasswordKeepsNewHistory() async throws {
        let server = FakeHomeserver()
        let alice = try await device(server, Self.alice, "A1")
        let bob = try await device(server, Self.bob, "B1")
        server.setMembers([Self.alice, Self.bob], roomID: Self.room)
        try await bob.machine.sendEncrypted(roomID: Self.room, type: EventType.message,
                                            content: OutboundTests().text("старое"))
        _ = await OutboundTests().read(server, alice)
        let code = try await alice.machine.enableRecovery(password: nil)

        // Ключ восстановления не спрашиваем: переписка под ним пропадает, хранилище заводится под паролем.
        let fresh = try await device(server, Self.alice, "A2")
        #expect(try await fresh.machine.unlockWithPassword("pw", iterations: Self.iterations) == .reset)
        await #expect(throws: E2EEError.wrongRecoveryKey) { try await fresh.machine.restoreBackup(recoveryKey: code) }
        try await bob.machine.store.markDeviceListsChanged([Self.alice])
        try await bob.machine.sendEncrypted(roomID: Self.room, type: EventType.message,
                                            content: OutboundTests().text("новое"))
        #expect(await OutboundTests().read(server, fresh).last == "новое")
        try await fresh.machine.uploadRoomKeysToBackup()

        // Каждый следующий вход паролем поднимает всё, что было после сброса.
        let third = try await device(server, Self.alice, "A3")
        #expect(try await third.machine.unlockWithPassword("pw", iterations: Self.iterations) == .opened(imported: 1))
        #expect(await OutboundTests().read(server, third).last == "новое")
        let fourth = try await device(server, Self.alice, "A4")
        #expect(try await fourth.machine.unlockWithPassword("pw", iterations: Self.iterations) == .opened(imported: 1))
    }

    @Test func wrongKeyChangesNothingAndKeyAloneOpensHistory() async throws {
        let server = FakeHomeserver()
        let alice = try await device(server, Self.alice, "A1")
        let bob = try await device(server, Self.bob, "B1")
        server.setMembers([Self.alice, Self.bob], roomID: Self.room)
        try await bob.machine.sendEncrypted(roomID: Self.room, type: EventType.message,
                                            content: OutboundTests().text("старое"))
        _ = await OutboundTests().read(server, alice)
        let code = try await alice.machine.enableRecovery(password: nil)
        let other = RecoveryKey.encode(Random.bytes(32))

        let fresh = try await device(server, Self.alice, "A2")
        await #expect(throws: E2EEError.wrongRecoveryKey) {
            try await fresh.machine.relockWithPassword(recoveryKey: other, password: "pw", iterations: Self.iterations)
        }
        await #expect(throws: E2EEError.wrongRecoveryKey) {
            try await fresh.machine.relockWithPassword(recoveryKey: "не ключ", password: "pw", iterations: Self.iterations)
        }

        // После перезапуска пароля в памяти нет: приложение только открывает хранилище ключом, без перезапирания.
        _ = try await fresh.machine.secretStorageKey(recoveryKey: code)
        try await fresh.machine.importCrossSigning(recoveryKey: code)
        #expect(try await fresh.machine.restoreBackup(recoveryKey: code).imported == 1)
        #expect(await OutboundTests().read(server, fresh) == ["старое"])
    }
}
