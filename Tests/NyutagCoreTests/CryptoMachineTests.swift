import Foundation
@testable import NyutagCore
import NyutagCrypto
import Testing

@Suite struct CryptoMachineTests {
    private static let bob = Session(userID: "@bob:nyutag.chat", deviceID: "BOBDEVICE", accessToken: "x",
                                     homeserver: URL(string: "http://127.0.0.1:1")!)

    private func machine() async throws -> CryptoMachine {
        let client = MatrixClient(homeserver: Self.bob.homeserver)
        return try await CryptoMachine(client: client, store: try Store.inMemory(), session: Self.bob)
    }

    @Test func deviceKeysAreSignedCanonically() async throws {
        let machine = try await machine()
        let keys = await machine.deviceKeys()
        #expect(keys["keys", "curve25519:BOBDEVICE"]?.string == machine.curve25519Key)
        #expect(CryptoMachine.verifySignature(keys, userID: "@bob:nyutag.chat", keyID: "BOBDEVICE",
                                              publicKey: machine.ed25519Key))
        // Порядок ключей и `unsigned` на подпись не влияют, правка содержимого — влияет.
        guard case .object(var fields) = keys else { Issue.record("не объект"); return }
        fields["unsigned"] = ["device_display_name": "Мак"]
        #expect(CryptoMachine.verifySignature(.object(fields), userID: "@bob:nyutag.chat", keyID: "BOBDEVICE",
                                              publicKey: machine.ed25519Key))
        fields["device_id"] = "OTHER"
        #expect(!CryptoMachine.verifySignature(.object(fields), userID: "@bob:nyutag.chat", keyID: "BOBDEVICE",
                                               publicKey: machine.ed25519Key))
    }

    /// Чужое устройство (только NyutagCrypto) присылает ключ комнаты через Olm, потом сообщение Megolm.
    @Test func roomKeyOverOlmThenMegolmMessage() async throws {
        let machine = try await machine()
        let otk = await machine.oneTimeKeyForTest()

        let alice = OlmAccount()
        var outbound = MegolmOutboundSession()
        let roomID = "!room:nyutag.chat"
        let payload: JSONValue = [
            "type": "m.room_key",
            "content": [
                "algorithm": "m.megolm.v1.aes-sha2", "room_id": .string(roomID),
                "session_id": .string(outbound.sessionID), "session_key": .string(outbound.sessionKey()),
            ],
            "sender": "@alice:nyutag.chat", "sender_device": "ALICEDEV",
            "recipient": "@bob:nyutag.chat", "recipient_keys": ["ed25519": .string(machine.ed25519Key)],
            "keys": ["ed25519": .string(alice.ed25519Key)],
        ]
        var olm = try alice.outboundSession(theirIdentityKey: machine.curve25519Key, theirOneTimeKey: otk)
        let sealed = try olm.encrypt(try payload.data())
        let toDevice = Event(type: "m.room.encrypted", sender: "@alice:nyutag.chat", content: [
            "algorithm": "m.olm.v1.curve25519-aes-sha2", "sender_key": .string(alice.curve25519Key),
            "ciphertext": [.init(stringLiteral: machine.curve25519Key): ["type": 0, "body": .string(sealed.body)]],
        ])
        let received = await machine.receiveToDevice([toDevice])
        #expect(received.map(\.type) == ["m.room_key"])
        #expect(received.first?.unsigned?["sender_ed25519"]?.string == alice.ed25519Key)
        #expect(await machine.megolmSessionCount() == 1)

        func roomEvent(_ eventID: String, body: String, room: String = roomID) throws -> Event {
            let plaintext: JSONValue = ["type": "m.room.message", "room_id": .string(room),
                                        "content": ["msgtype": "m.text", "body": .string(body)]]
            return Event(eventID: eventID, type: "m.room.encrypted", sender: "@alice:nyutag.chat", originServerTS: 1, content: [
                "algorithm": "m.megolm.v1.aes-sha2", "sender_key": .string(alice.curve25519Key),
                "session_id": .string(outbound.sessionID), "device_id": "ALICEDEV",
                "ciphertext": .string(try outbound.encrypt(try plaintext.data())),
            ], roomID: room)
        }
        let first = try roomEvent("$1", body: "сайн байна")
        let decrypted = try await machine.decrypt(first, roomID: roomID)
        #expect(decrypted.event.type == "m.room.message")
        #expect(decrypted.event.content["body"]?.string == "сайн байна")
        #expect(decrypted.isVerifiedSession)
        #expect(decrypted.messageIndex == 0)
        // То же событие повторно — можно, тот же индекс под другим event_id — повтор.
        _ = try await machine.decrypt(first, roomID: roomID)
        let forged = Event(eventID: "$forged", type: first.type, sender: first.sender, content: first.content)
        await #expect(throws: E2EEError.replay) { try await machine.decrypt(forged, roomID: roomID) }
        // Ключ комнаты не годится для другой комнаты.
        let elsewhere = try roomEvent("$2", body: "x", room: "!other:nyutag.chat")
        await #expect(throws: E2EEError.missingSession(sessionID: outbound.sessionID)) {
            try await machine.decrypt(elsewhere, roomID: "!other:nyutag.chat")
        }
        // Без sender_key (новые клиенты его не шлют) сессия ищется по session_id.
        var modern = try roomEvent("$3", body: "без sender_key")
        if case .object(var content) = modern.content {
            content["sender_key"] = nil
            modern = Event(eventID: "$3", type: modern.type, sender: modern.sender, content: .object(content))
        }
        #expect(try await machine.decrypt(modern, roomID: roomID).event.content["body"]?.string == "без sender_key")
    }

    @Test func toDeviceForSomeoneElseIsRejected() async throws {
        let machine = try await machine()
        let otk = await machine.oneTimeKeyForTest()
        let alice = OlmAccount()
        let payload: JSONValue = [
            "type": "m.room_key", "content": [:], "sender": "@alice:nyutag.chat",
            "recipient": "@mallory:nyutag.chat", "recipient_keys": ["ed25519": .string(machine.ed25519Key)],
            "keys": ["ed25519": .string(alice.ed25519Key)],
        ]
        var olm = try alice.outboundSession(theirIdentityKey: machine.curve25519Key, theirOneTimeKey: otk)
        let sealed = try olm.encrypt(try payload.data())
        let event = Event(type: "m.room.encrypted", sender: "@alice:nyutag.chat", content: [
            "algorithm": "m.olm.v1.curve25519-aes-sha2", "sender_key": .string(alice.curve25519Key),
            "ciphertext": [.init(stringLiteral: machine.curve25519Key): ["type": 0, "body": .string(sealed.body)]],
        ])
        #expect(await machine.receiveToDevice([event]).isEmpty)
    }

    @Test func accountSurvivesRestart() async throws {
        let store = try Store.inMemory()
        let client = MatrixClient(homeserver: Self.bob.homeserver)
        let first = try await CryptoMachine(client: client, store: store, session: Self.bob)
        let second = try await CryptoMachine(client: client, store: store, session: Self.bob)
        #expect(first.curve25519Key == second.curve25519Key)
        #expect(first.ed25519Key == second.ed25519Key)
    }
}

extension CryptoMachine {
    /// Одноразовый ключ, как если бы его выдал сервер по `/keys/claim`.
    func oneTimeKeyForTest() -> String {
        account.generateOneTimeKeys(1)
        let key = account.unpublishedOneTimeKeys.values.first!
        account.markKeysPublished()
        return key
    }
}
