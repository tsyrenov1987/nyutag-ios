import Foundation
@testable import NyutagCore
import Testing

/// Текст пуша: событие с сервера, расшифровка ключами из хранилища, разбор вида сообщения.
@Suite struct PushReaderTests {
    static let room = "!room:nyutag.chat"
    static let alice = "@alice:nyutag.chat"
    static let bob = "@bob:nyutag.chat"

    @Test func encryptedMessageIsDecrypted() async throws {
        let server = FakeHomeserver()
        let aliceSession = server.session(user: Self.alice, device: "A1")
        let alice = try await CryptoMachine(client: server.client(for: aliceSession), store: try Store.inMemory(),
                                            session: aliceSession)
        try await alice.publishKeys(serverCount: nil)
        // У Боба одно хранилище на приложение и расширение: приложение приняло ключ, расширение читает.
        let bobSession = server.session(user: Self.bob, device: "B1")
        let bobStore = try Store.inMemory()
        let bob = try await CryptoMachine(client: server.client(for: bobSession), store: bobStore, session: bobSession)
        try await bob.publishKeys(serverCount: nil)
        server.setMembers([Self.alice, Self.bob], roomID: Self.room)
        try await bobStore.setState(Event(type: EventType.member, sender: Self.alice, stateKey: Self.alice,
                                          content: ["membership": "join", "displayname": "Алиса"], roomID: Self.room))

        try await alice.sendEncrypted(roomID: Self.room, type: EventType.message,
                                      content: ["msgtype": "m.text", "body": "> <@bob:nyutag.chat> где ты\n\nдома"])
        let eventID = try #require(server.events(roomID: Self.room).last?.eventID)
        let reader = PushReader(client: server.client(for: bobSession), store: bobStore, session: bobSession)

        // Ключ ещё не дошёл до устройства — нейтральный пуш.
        #expect(try await reader.preview(roomID: Self.room, eventID: eventID).kind == .locked)

        _ = await bob.receiveToDevice(server.takeToDevice(user: Self.bob, device: "B1"))
        let preview = try await reader.preview(roomID: Self.room, eventID: eventID)
        #expect(preview.kind == .text("дома"))
        #expect(preview.sender == Self.alice)
        #expect(preview.senderName == "Алиса")
        // Приложение позже расшифрует то же событие: защита от повтора не должна его отвергнуть.
        let again = try await bob.decrypt(try #require(server.events(roomID: Self.room).last), roomID: Self.room)
        #expect(again.event.content["body"]?.string?.hasSuffix("дома") == true)
    }

    @Test func noAccountMeansNoDecryption() async throws {
        let server = FakeHomeserver()
        let session = server.session(user: Self.bob, device: "B1")
        let store = try Store.inMemory()
        let client = server.client(for: session)
        try await client.send(roomID: Self.room, type: EventType.encrypted,
                              content: ["algorithm": "m.megolm.v1.aes-sha2", "session_id": "s", "ciphertext": "c"])
        let eventID = try #require(server.events(roomID: Self.room).last?.eventID)
        let preview = try await PushReader(client: client, store: store, session: session)
            .preview(roomID: Self.room, eventID: eventID)
        #expect(preview.kind == .locked)
        // Расширение не заводит свой Olm-аккаунт.
        #expect(try await store.cryptoBlob("account") == nil)
    }

    @Test func kinds() {
        func kind(_ type: String, _ content: JSONValue, stateKey: String? = nil) -> PushPreview.Kind {
            PushReader.kind(of: Event(type: type, sender: Self.alice, stateKey: stateKey, content: content), me: Self.bob)
        }
        #expect(kind(EventType.message, ["msgtype": "m.image", "body": "a.jpg"]) == .image)
        #expect(kind(EventType.message, ["msgtype": "m.audio", "body": "v.ogg"]) == .audio)
        #expect(kind(EventType.message, ["msgtype": "m.text", "body": "* старое",
                                         "m.new_content": ["msgtype": "m.text", "body": "новое"]]) == .text("новое"))
        #expect(kind(EventType.member, ["membership": "invite"], stateKey: Self.bob) == .invite)
        #expect(kind(EventType.member, ["membership": "invite"], stateKey: "@c:nyutag.chat") == .other)
        #expect(kind(EventType.call, [:]) == .call)
        #expect(kind("m.sticker", ["body": "кот"]) == .sticker)
        #expect(kind(EventType.message, ["msgtype": "m.text"]) == .other)
        #expect(PushReader.withoutReplyQuote("> цитата без ответа") == "> цитата без ответа")
        #expect(PushReader.withoutReplyQuote("просто текст") == "просто текст")
    }
}
