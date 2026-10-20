import Foundation
@testable import NyutagCore
import NyutagCrypto
import Testing

/// Кросс-подпись, запрос ключей у своих устройств и отказы в ключе на поддельном сервере.
@Suite struct KeySharingTests {
    static let room = "!room:nyutag.chat"
    static let alice = "@alice:nyutag.chat"
    static let bob = "@bob:nyutag.chat"

    typealias Device = OutboundTests.Device

    func device(_ server: FakeHomeserver, _ user: String, _ id: String) async throws -> Device {
        try await OutboundTests().device(server, user, id)
    }

    func inbox(_ server: FakeHomeserver, _ device: Device) async {
        _ = await device.machine.receiveToDevice(server.takeToDevice(user: device.session.userID,
                                                                     device: device.session.deviceID))
    }

    func text(_ body: String) -> JSONValue { ["msgtype": "m.text", "body": .string(body)] }

    /// Второе устройство получает те же ключи кросс-подписи (как после ввода recovery-кода).
    func adopt(_ from: Device, _ to: Device) async throws {
        let master = try #require(try await from.machine.ownCrossSigningKey(.master))
        let selfSigning = try #require(try await from.machine.ownCrossSigningKey(.selfSigning))
        try await to.machine.adoptCrossSigning(master: master, selfSigning: selfSigning,
                                               userSigning: try await from.machine.ownCrossSigningKey(.userSigning))
    }

    @Test func bootstrapAsksPasswordAndSignsDevice() async throws {
        let server = FakeHomeserver()
        server.requirePassword = "пароль"
        let alice = try await device(server, Self.alice, "A1")
        let bob = try await device(server, Self.bob, "B1")

        await #expect(throws: E2EEError.self) { try await alice.machine.bootstrapCrossSigning(password: nil) }
        #expect(await !alice.machine.hasCrossSigningKeys)
        try await alice.machine.bootstrapCrossSigning(password: "пароль")
        #expect(await alice.machine.hasCrossSigningKeys)

        // Сама Алиса видит своё устройство подтверждённым.
        let own = try #require(try await alice.machine.devices(for: [Self.alice]).first)
        #expect(own.crossSigned)
        #expect(await alice.machine.isVerified(own))
        // Боб видит подпись, но мастер-ключ Алисы им не подтверждён.
        let seen = try #require(try await bob.machine.devices(for: [Self.alice]).first)
        #expect(seen.crossSigned)
        #expect(await !bob.machine.isVerified(seen))
        #expect(await bob.machine.crossSigningIdentity(userID: Self.alice)?.verified == false)
    }

    @Test func forgedSelfSigningKeyDoesNotVerify() async throws {
        let server = FakeHomeserver()
        let alice = try await device(server, Self.alice, "A1")
        let other = try await device(server, Self.alice, "A2")
        try await alice.machine.bootstrapCrossSigning(password: nil)
        // Сервер подсовывает чужой мастер-ключ: A2 с настоящими ключами больше не верит своей личности.
        let fake = try await device(server, Self.alice, "A3")
        try await fake.machine.bootstrapCrossSigning(password: nil)
        try await adopt(alice, other)
        let devices = try await other.machine.devices(for: [Self.alice])
        #expect(devices.allSatisfy { !$0.crossSigned || $0.deviceID == "A3" })
        for device in devices { #expect(await !other.machine.isVerified(device)) }
    }

    @Test func keyRequestAnsweredOnlyForVerifiedOwnDevice() async throws {
        let server = FakeHomeserver()
        let alice1 = try await device(server, Self.alice, "A1")
        let bob = try await device(server, Self.bob, "B1")
        try await alice1.machine.bootstrapCrossSigning(password: nil)
        server.setMembers([Self.alice, Self.bob], roomID: Self.room)
        try await bob.machine.sendEncrypted(roomID: Self.room, type: EventType.message, content: text("до A2"))
        await inbox(server, alice1)

        // Новые устройства Алисы: A2 подтверждено (ключи кросс-подписи подняты), A3 — нет.
        let alice2 = try await device(server, Self.alice, "A2")
        let alice3 = try await device(server, Self.alice, "A3")
        try await adopt(alice1, alice2)
        let event = try #require(server.events(roomID: Self.room).first)
        await #expect(throws: E2EEError.missingSession(sessionID: event.content["session_id"]!.string!)) {
            try await alice2.machine.decrypt(event, roomID: Self.room)
        }
        #expect(try await alice2.machine.requestRoomKey(for: event, roomID: Self.room))
        #expect(try await !alice2.machine.requestRoomKey(for: event, roomID: Self.room))
        #expect(try await alice3.machine.requestRoomKey(for: event, roomID: Self.room))

        // A1 видит оба запроса, отвечает только A2.
        await inbox(server, alice1)
        let toA3 = server.takeToDevice(user: Self.alice, device: "A3")
        #expect(!toA3.contains { $0.type == EventType.encrypted })
        _ = await alice3.machine.receiveToDevice(toA3)
        await #expect(throws: E2EEError.self) { try await alice3.machine.decrypt(event, roomID: Self.room) }
        await inbox(server, alice2)
        let opened = try await alice2.machine.decrypt(event, roomID: Self.room)
        #expect(opened.event.content["body"]?.string == "до A2")
        #expect(!opened.isVerifiedSession)
        // Запрос закрыт: другим устройствам ушла отмена.
        #expect(await !alice2.machine.hasKeyRequest(sessionID: opened.sessionID, senderKey: ""))
        let cancels = server.takeToDevice(user: Self.alice, device: "A1")
            .filter { $0.content["action"]?.string == "request_cancellation" }
        #expect(cancels.count == 1)
    }

    @Test func forwardedKeyWithoutRequestIsIgnored() async throws {
        let server = FakeHomeserver()
        let alice1 = try await device(server, Self.alice, "A1")
        let bob = try await device(server, Self.bob, "B1")
        try await alice1.machine.bootstrapCrossSigning(password: nil)
        server.setMembers([Self.alice, Self.bob], roomID: Self.room)
        try await bob.machine.sendEncrypted(roomID: Self.room, type: EventType.message, content: text("x"))
        await inbox(server, alice1)
        let alice2 = try await device(server, Self.alice, "A2")
        try await adopt(alice1, alice2)
        let event = try #require(server.events(roomID: Self.room).first)

        // A1 сам шлёт ключ, о котором A2 не просил: A2 его не берёт.
        let request = Event(type: EventType.roomKeyRequest, sender: Self.alice, content: [
            "action": "request", "requesting_device_id": "A2", "request_id": "r1",
            "body": ["algorithm": .string(CryptoMachine.megolmAlgorithm), "room_id": .string(Self.room),
                     "session_id": event.content["session_id"]!, "sender_key": event.content["sender_key"]!],
        ])
        #expect(try await alice1.machine.answerRoomKeyRequest(request))
        await inbox(server, alice2)
        await #expect(throws: E2EEError.self) { try await alice2.machine.decrypt(event, roomID: Self.room) }
    }

    @Test func noOlmChannelGivesWithheldOnce() async throws {
        let server = FakeHomeserver()
        let alice = try await device(server, Self.alice, "A1")
        let bob = try await device(server, Self.bob, "B1")
        server.dropOneTimeKeys(user: Self.bob, device: "B1")
        server.setMembers([Self.alice, Self.bob], roomID: Self.room)

        try await alice.machine.sendEncrypted(roomID: Self.room, type: EventType.message, content: text("1"))
        try await alice.machine.sendEncrypted(roomID: Self.room, type: EventType.message, content: text("2"))
        let received = server.takeToDevice(user: Self.bob, device: "B1")
        #expect(received.map(\.type) == [CryptoMachine.withheldType])
        _ = await bob.machine.receiveToDevice(received)
        let event = try #require(server.events(roomID: Self.room).first)
        await #expect(throws: E2EEError.withheld(code: "m.no_olm", reason: "Нет одноразовых ключей для устройства")) {
            try await bob.machine.decrypt(event, roomID: Self.room)
        }
    }
}
