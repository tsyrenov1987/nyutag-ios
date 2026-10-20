import Foundation
@testable import NyutagCore
import NyutagCrypto
import Testing

/// Отправка в зашифрованную комнату между несколькими устройствами на поддельном сервере.
@Suite struct OutboundTests {
    static let room = "!room:nyutag.chat"
    static let alice = "@alice:nyutag.chat"
    static let bob = "@bob:nyutag.chat"

    struct Device {
        let machine: CryptoMachine
        let session: Session
    }

    func device(_ server: FakeHomeserver, _ user: String, _ id: String) async throws -> Device {
        let session = server.session(user: user, device: id)
        let machine = try await CryptoMachine(client: server.client(for: session), store: try Store.inMemory(),
                                              session: session)
        try await machine.publishKeys(serverCount: nil)
        return Device(machine: machine, session: session)
    }

    /// Принять to-device и расшифровать все события комнаты; nil там, где ключа нет.
    func read(_ server: FakeHomeserver, _ device: Device) async -> [String?] {
        _ = await device.machine.receiveToDevice(server.takeToDevice(user: device.session.userID,
                                                                     device: device.session.deviceID))
        var bodies: [String?] = []
        for event in server.events(roomID: Self.room) {
            let decrypted = try? await device.machine.decrypt(event, roomID: Self.room)
            bodies.append(decrypted?.event.content["body"]?.string)
        }
        return bodies
    }

    func text(_ body: String) -> JSONValue { ["msgtype": "m.text", "body": .string(body)] }

    @Test func messageReachesEveryDeviceOnce() async throws {
        let server = FakeHomeserver()
        let alice = try await device(server, Self.alice, "A1")
        let bob1 = try await device(server, Self.bob, "B1")
        let bob2 = try await device(server, Self.bob, "B2")
        let aliceOther = try await device(server, Self.alice, "A2")
        server.setMembers([Self.alice, Self.bob], roomID: Self.room)

        try await alice.machine.sendEncrypted(roomID: Self.room, type: EventType.message, content: text("сайн байна"))
        // Ключ комнаты получили три других устройства, своему (A1) он не шлётся.
        #expect(server.takeToDevice(user: Self.alice, device: "A1").isEmpty)
        #expect(await read(server, bob1) == ["сайн байна"])
        #expect(await read(server, bob2) == ["сайн байна"])
        #expect(await read(server, aliceOther) == ["сайн байна"])
        // Своё сообщение читается своей же копией ключа.
        #expect(await read(server, alice) == ["сайн байна"])

        // Второе сообщение идёт той же сессией: ключ повторно не рассылается.
        try await alice.machine.sendEncrypted(roomID: Self.room, type: EventType.message, content: text("хэр байнат"))
        #expect(server.takeToDevice(user: Self.bob, device: "B1").isEmpty)
        #expect(await read(server, bob1) == ["сайн байна", "хэр байнат"])
        let ids = server.events(roomID: Self.room).map { $0.content["session_id"]?.string }
        #expect(ids[0] == ids[1])

        // Боб отвечает: у Боба сессия Olm к Алисе уже есть (входящая), исходящая заводится по claim.
        try await bob1.machine.sendEncrypted(roomID: Self.room, type: EventType.message, content: text("сайн"))
        #expect(await read(server, alice) == ["сайн байна", "хэр байнат", "сайн"])
        #expect(await read(server, bob2) == ["сайн байна", "хэр байнат", "сайн"])
    }

    @Test func keyRotatesWhenSomeoneLeaves() async throws {
        let server = FakeHomeserver()
        let alice = try await device(server, Self.alice, "A1")
        let bob = try await device(server, Self.bob, "B1")
        server.setMembers([Self.alice, Self.bob], roomID: Self.room)
        try await alice.machine.sendEncrypted(roomID: Self.room, type: EventType.message, content: text("при Бобе"))
        #expect(await read(server, bob) == ["при Бобе"])

        server.setMembers([Self.alice], roomID: Self.room)
        try await alice.machine.sendEncrypted(roomID: Self.room, type: EventType.message, content: text("без Боба"))
        let ids = server.events(roomID: Self.room).map { $0.content["session_id"]?.string }
        #expect(ids[0] != ids[1])
        #expect(await read(server, bob) == ["при Бобе", nil])
        #expect(await read(server, alice) == ["при Бобе", "без Боба"])
    }

    @Test func newDeviceGetsKeyFromCurrentIndexOnly() async throws {
        let server = FakeHomeserver()
        let alice = try await device(server, Self.alice, "A1")
        _ = try await device(server, Self.bob, "B1")
        server.setMembers([Self.alice, Self.bob], roomID: Self.room)
        try await alice.machine.sendEncrypted(roomID: Self.room, type: EventType.message, content: text("раньше"))

        let late = try await device(server, Self.bob, "B2")
        // /sync сообщил, что у Боба сменились устройства.
        try await alice.machine.store.markDeviceListsChanged([Self.bob])
        try await alice.machine.sendEncrypted(roomID: Self.room, type: EventType.message, content: text("позже"))
        let ids = server.events(roomID: Self.room).map { $0.content["session_id"]?.string }
        #expect(ids[0] == ids[1])
        #expect(await read(server, late) == [nil, "позже"])
    }

    @Test func forgedDeviceKeysAndOneTimeKeysAreIgnored() async throws {
        let server = FakeHomeserver()
        let alice = try await device(server, Self.alice, "A1")
        _ = try await device(server, Self.bob, "B1")
        let mallory = Ed25519KeyPair()
        // Сервер подменяет ключ подписи устройства B1 своим: подпись больше не сходится.
        server.tamperDeviceKeys = { user, device, keys in
            guard user == Self.bob, case .object(var fields) = keys, case .object(var inner)? = fields["keys"] else { return keys }
            inner["ed25519:\(device)"] = .string(mallory.publicKeyBase64)
            fields["keys"] = .object(inner)
            return .object(fields)
        }
        server.setMembers([Self.alice, Self.bob], roomID: Self.room)
        #expect(try await alice.machine.devices(for: [Self.bob]).isEmpty)
        try await alice.machine.sendEncrypted(roomID: Self.room, type: EventType.message, content: text("x"))
        #expect(server.takeToDevice(user: Self.bob, device: "B1").isEmpty)
        #expect(server.oneTimeKeyCount(user: Self.bob, device: "B1") == 50)
    }

    @Test func roomKeysGoToBackup() async throws {
        let server = FakeHomeserver()
        let alice = try await device(server, Self.alice, "A1")
        let bob = try await device(server, Self.bob, "B1")
        server.setMembers([Self.alice, Self.bob], roomID: Self.room)
        let backupKey = BackupKey()
        try await bob.machine.store.setCryptoBlob("backup_key", backupKey.keyPair.rawRepresentation)
        try await bob.machine.store.setMeta("e2ee_backup_version", "1")

        try await alice.machine.sendEncrypted(roomID: Self.room, type: EventType.message, content: text("в бэкап"))
        _ = await read(server, bob)
        #expect(try await bob.machine.uploadRoomKeysToBackup() == 1)
        #expect(try await bob.machine.uploadRoomKeysToBackup() == 0)

        // Запись из бэкапа расшифровывается ключом бэкапа и открывает сообщение.
        let sessionID = try #require(server.events(roomID: Self.room).first?.content["session_id"]?.string)
        let record = try #require(server.backup[Self.room]?[sessionID])
        #expect(record["first_message_index"]?.int == 0)
        let data = try #require(record["session_data"])
        let plaintext = try backupKey.decrypt(BackupSessionData(ephemeral: data["ephemeral"]!.string!,
                                                                ciphertext: data["ciphertext"]!.string!,
                                                                mac: data["mac"]!.string!))
        let json = try JSONValue(data: plaintext)
        #expect(json["sender_key"]?.string == alice.machine.curve25519Key)
        #expect(json["sender_claimed_keys", "ed25519"]?.string == alice.machine.ed25519Key)
        let session = try MegolmInboundSession(exportedKey: try #require(json["session_key"]?.string))
        let event = try #require(server.events(roomID: Self.room).first)
        let opened = try session.decrypt(try #require(event.content["ciphertext"]?.string))
        #expect(try JSONValue(data: opened.plaintext)["content", "body"]?.string == "в бэкап")

        // Сервер сменил версию бэкапа: старый ключ больше не годится.
        try await bob.machine.store.setMeta("e2ee_backup_version", "2")
        try await bob.machine.store.resetMegolmBackedUp()
        await #expect(throws: E2EEError.noBackup) { try await bob.machine.uploadRoomKeysToBackup() }
    }
}
