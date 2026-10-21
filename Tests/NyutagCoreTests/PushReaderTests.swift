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

    /// Пуш в том виде, в каком его собирает шлюз с флагом `nyutag_cipher`.
    static func gatewayPush(_ event: Event) throws -> [AnyHashable: Any] {
        let carried = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            JSONValue.object(["sender": .string(event.sender ?? ""), "content": event.content])))
        return ["aps": ["alert": ["loc-key": "MSG_FROM_USER"], "mutable-content": 1],
                "room_id": event.roomID ?? Self.room, "event_id": event.eventID ?? "", "nyutag_event": carried]
    }

    @Test func carriedCipherDecryptsWithoutServer() async throws {
        let server = FakeHomeserver()
        let aliceSession = server.session(user: Self.alice, device: "A1")
        let alice = try await CryptoMachine(client: server.client(for: aliceSession), store: try Store.inMemory(),
                                            session: aliceSession)
        try await alice.publishKeys(serverCount: nil)
        let bobSession = server.session(user: Self.bob, device: "B1")
        let bobStore = try Store.inMemory()
        let bob = try await CryptoMachine(client: server.client(for: bobSession), store: bobStore, session: bobSession)
        try await bob.publishKeys(serverCount: nil)
        server.setMembers([Self.alice, Self.bob], roomID: Self.room)
        try await alice.sendEncrypted(roomID: Self.room, type: EventType.message,
                                      content: ["msgtype": "m.image", "body": "кот.jpg"])
        _ = await bob.receiveToDevice(server.takeToDevice(user: Self.bob, device: "B1"))
        let sent = try #require(server.events(roomID: Self.room).last)
        let eventID = try #require(sent.eventID)

        // Расширение без пути к ядру: другой сервер, где события нет и токен чужой.
        let offline = FakeHomeserver().client(accessToken: nil)
        let reader = PushReader(client: offline, store: bobStore, session: bobSession)
        await #expect(throws: MatrixError.self) { try await reader.preview(roomID: Self.room, eventID: eventID) }

        let carried = try #require(ApplePusher.carriedEvent(in: try Self.gatewayPush(sent)))
        #expect(carried.eventID == eventID && carried.sender == Self.alice && carried.type == EventType.encrypted)
        let preview = try await reader.preview(roomID: Self.room, eventID: eventID, carried: carried)
        #expect(preview.kind == .image)
        #expect(preview.sender == Self.alice)
    }

    @Test func carriedEventNeedsCipher() throws {
        let event = Event(eventID: "$e", type: EventType.encrypted, sender: Self.alice,
                          content: ["algorithm": "m.megolm.v1.aes-sha2", "ciphertext": "c", "session_id": "s"],
                          roomID: Self.room)
        var push = try Self.gatewayPush(event)
        #expect(ApplePusher.carriedEvent(in: push)?.content == event.content)
        // Шлюз не вложил шифротекст (не влез или старый пушер) — расширение идёт прежним путём.
        push["nyutag_event"] = nil
        #expect(ApplePusher.carriedEvent(in: push) == nil)
        #expect(ApplePusher.carriedEvent(in: try Self.gatewayPush(Event(eventID: "$e", type: EventType.encrypted,
            sender: Self.alice, content: ["algorithm": "m.megolm.v1.aes-sha2"], roomID: Self.room))) == nil)
        push = try Self.gatewayPush(event)
        push["event_id"] = nil
        #expect(ApplePusher.carriedEvent(in: push) == nil)
    }

    @Test func pusherAsksGatewayForCipher() async throws {
        let server = FakeHomeserver()
        let session = server.session(user: Self.bob, device: "B1")
        let client = server.client(for: session)
        let token = Data([0x0a, 0xff, 0x01])
        try await client.registerApplePush(token: token, environment: .production, deviceName: "iPhone", language: "ru")
        try await client.registerApplePush(token: token, environment: .production, deviceName: "iPhone", language: "ru")
        let pusher = try #require(server.pushers(user: Self.bob).first)
        #expect(server.pushers(user: Self.bob).count == 1)
        #expect(pusher["app_id"] == "chat.nyutag.messenger.ios.prod")
        #expect(pusher["pushkey"] == "Cv8B")
        #expect(pusher["data", "url"] == "http://127.0.0.1:5000/_matrix/push/v1/notify")
        #expect(pusher["data", "nyutag_cipher"] == 1)
        #expect(pusher["data", "default_payload", "aps", "mutable-content"] == 1)
        #expect(pusher["data", "format"] == nil)
        try await client.removeApplePush(token: token, environment: .production)
        #expect(server.pushers(user: Self.bob).isEmpty)
    }

    @Test func betaBuildHasItsOwnGatewayApp() {
        // Шлюз держит для β отдельное приложение с topic chat.nyutag.messenger.dev.
        #expect(ApplePusher.appID(.beta) == "chat.nyutag.messenger.ios.beta")
        #expect(ApplePusher.appID(.sandbox) == "chat.nyutag.messenger.ios.dev")
    }

    @Test func gatewayCaptionIsReadWhenEventIsNot() {
        func info(_ key: String, _ args: [String]) -> [AnyHashable: Any] {
            ["aps": ["alert": ["loc-key": key, "loc-args": args], "mutable-content": 1], "room_id": Self.room,
             "event_id": "$e"]
        }
        let open = ApplePusher.gatewayPreview(in: info("MSG_FROM_USER_IN_ROOM_WITH_CONTENT", ["Алиса", "Проверка", "привет"]))
        #expect(open?.senderName == "Алиса")
        #expect(open?.roomName == "Проверка")
        #expect(open?.kind == .text("привет"))
        #expect(open?.isDirect == false)
        let emote = ApplePusher.gatewayPreview(in: info("ACTION_FROM_USER_IN_ROOM", ["Проверка", "Алиса", "машет"]))
        #expect(emote?.senderName == "Алиса")
        #expect(emote?.roomName == "Проверка")
        let locked = ApplePusher.gatewayPreview(in: info("MSG_FROM_USER", ["Алиса"]))
        #expect(locked?.kind == .locked)
        #expect(locked?.isDirect == true)
        #expect(ApplePusher.gatewayPreview(in: info("SOMETHING_NEW", ["Алиса"])) == nil)
        #expect(ApplePusher.gatewayPreview(in: ["room_id": Self.room]) == nil)
    }
}
