import Foundation
@testable import NyutagCore
import Testing

@Suite struct SyncTests {
    static func fixture() throws -> JSONValue {
        let url = try #require(Bundle.module.url(forResource: "sync", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONValue(data: Data(contentsOf: url))
    }

    @Test func parsesSyncResponse() throws {
        let response = try SyncResponse(json: try Self.fixture())
        #expect(response.nextBatch == "s72595_4483_1934")
        #expect(response.joined.count == 2)
        #expect(response.invited.count == 1)
        #expect(response.left.count == 1)
        #expect(response.accountData.map(\.type) == ["m.direct", "chat.nyutag.chat_layout"])
        #expect(response.toDevice.first?.type == "m.room.encrypted")
        #expect(response.deviceListsChanged == ["@b:nyutag.chat"])
        #expect(response.oneTimeKeysCount["signed_curve25519"] == 50)
        #expect(response.unusedFallbackKeys == ["signed_curve25519"])

        let group = try #require(response.joined["!group:nyutag.chat"])
        #expect(group.timeline.events.count == 3)
        #expect(group.timeline.limited)
        #expect(group.timeline.prevBatch == "t34-23535_0_0")
        #expect(group.timeline.events[0].roomID == "!group:nyutag.chat")
        #expect(group.timeline.events[2].isState)
        #expect(group.state.count == 4)
        #expect(group.ephemeral.count == 2)
        #expect(group.unread == .init(highlight: 1, notification: 2))
        #expect(group.summary.heroes == ["@b:nyutag.chat", "@c:nyutag.chat"])
        #expect(group.summary.joinedCount == 3)
    }

    @Test func appliesSyncToStore() async throws {
        let store = try Store.inMemory()
        let client = MatrixClient(homeserver: URL(string: "http://127.0.0.1:1")!)
        let session = Session(userID: "@a:nyutag.chat", deviceID: "D", accessToken: "t", homeserver: client.homeserver)
        let engine = SyncEngine(client: client, store: store, session: session)
        let response = try SyncResponse(json: try Self.fixture())
        let update = try await engine.apply(response, isInitial: true)
        #expect(update.changedRooms == ["!group:nyutag.chat", "!space:nyutag.chat", "!inv:nyutag.chat", "!old:nyutag.chat"])

        let group = try #require(try await store.room("!group:nyutag.chat"))
        #expect(group.membership == .join)
        #expect(group.name == "Нютаг тест")
        #expect(group.topic == "Тема")
        #expect(group.isEncrypted)
        #expect(!group.isSpace)
        #expect(group.heroes.count == 2)
        #expect(group.joinedCount == 3)
        #expect(group.highlightCount == 1)
        #expect(group.notificationCount == 2)
        #expect(group.latestTS == 1_760_000_000_003)
        #expect(group.prevBatch == "t34-23535_0_0")
        #expect(try await store.eventCount(in: "!group:nyutag.chat") == 3)
        #expect(try await store.state("!group:nyutag.chat", type: EventType.member, stateKey: "@a:nyutag.chat")?["displayname"]?.string == "Аюр")
        #expect(try await store.receipt(roomID: "!group:nyutag.chat", userID: "@b:nyutag.chat") == "$1")
        #expect(try await store.receipt(roomID: "!group:nyutag.chat", userID: "@a:nyutag.chat") == "$1")
        #expect(try await store.accountData("m.fully_read", roomID: "!group:nyutag.chat")?["event_id"]?.string == "$1")

        let space = try #require(try await store.room("!space:nyutag.chat"))
        #expect(space.isSpace)

        let invite = try #require(try await store.room("!inv:nyutag.chat"))
        #expect(invite.membership == .invite)
        #expect(invite.name == "Приглашение")
        #expect(invite.isDirect)

        #expect(try await store.room("!old:nyutag.chat")?.membership == .leave)
        #expect(try await store.accountData(EventType.chatLayout)?["folders"]?[0]?["name"]?.string == "Работа")
        #expect(try await store.syncToken == "s72595_4483_1934")

        // Повторное применение того же ответа не дублирует события.
        _ = try await engine.apply(response, isInitial: false)
        #expect(try await store.eventCount(in: "!group:nyutag.chat") == 3)
    }

    @Test func directAccountDataMarksRooms() async throws {
        let store = try Store.inMemory()
        let client = MatrixClient(homeserver: URL(string: "http://127.0.0.1:1")!)
        let session = Session(userID: "@a:nyutag.chat", deviceID: "D", accessToken: "t", homeserver: client.homeserver)
        let engine = SyncEngine(client: client, store: store, session: session)
        func sync(_ batch: String, rooms: JSONValue = [:], direct: JSONValue? = nil) async throws -> SyncUpdate {
            let accountData: JSONValue = .array(direct.map { [["type": "m.direct", "content": $0]] } ?? [])
            let json: JSONValue = ["next_batch": .string(batch), "rooms": ["join": rooms],
                                   "account_data": ["events": accountData]]
            return try await engine.apply(try SyncResponse(json: json), isInitial: false)
        }
        let empty: JSONValue = ["timeline": ["events": []]]

        // Комната пришла раньше m.direct: признак ставится, когда m.direct приходит.
        _ = try await sync("1", rooms: ["!dm:nyutag.chat": empty, "!g:nyutag.chat": empty])
        #expect(try await store.room("!dm:nyutag.chat")?.isDirect == false)
        let update = try await sync("2", direct: ["@b:nyutag.chat": ["!dm:nyutag.chat"]])
        #expect(update.changedRooms == ["!dm:nyutag.chat"])
        #expect(try await store.room("!dm:nyutag.chat")?.isDirect == true)
        #expect(try await store.room("!g:nyutag.chat")?.isDirect == false)

        // Новая комната, уже записанная в m.direct, сразу личная.
        _ = try await sync("3", rooms: ["!dm2:nyutag.chat": empty], direct: ["@b:nyutag.chat": ["!dm:nyutag.chat", "!dm2:nyutag.chat"]])
        _ = try await sync("4", rooms: ["!dm2:nyutag.chat": empty])
        #expect(try await store.room("!dm2:nyutag.chat")?.isDirect == true)

        // Убрали из m.direct — признак снимается.
        _ = try await sync("5", direct: ["@b:nyutag.chat": ["!dm2:nyutag.chat"]])
        #expect(try await store.room("!dm:nyutag.chat")?.isDirect == false)
        #expect(try await store.room("!dm2:nyutag.chat")?.isDirect == true)
    }

    @Test func syncFilterIsCompactJSON() {
        let filter = SyncFilter.initial(timelineLimit: 20).canonicalJSON()
        #expect(filter.contains(#""limit":20"#))
        #expect(!filter.contains(" "))
    }
}
