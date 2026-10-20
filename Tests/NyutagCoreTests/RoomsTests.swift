import Foundation
@testable import NyutagCore
import Testing

struct RoomsTests {
    private func message(_ id: Int, room: String = "!r:nyutag.chat") -> Event {
        Event(eventID: "$m\(id)", type: EventType.message, sender: "@u:nyutag.chat", originServerTS: id,
              content: ["msgtype": "m.text", "body": .string("№\(id)")], roomID: room)
    }

    @Test func prependPutsHistoryBeforeTimeline() async throws {
        let store = try Store.inMemory()
        try await store.append([message(10), message(11)])
        // /messages dir=b отдаёт от новых к старым, с повтором уже известного события.
        let added = try await store.prepend([message(10), message(9), message(8)], roomID: "!r:nyutag.chat")
        #expect(added == 2)
        try await store.append([message(12)])
        let ids = try await store.events(in: "!r:nyutag.chat").compactMap(\.eventID)
        #expect(ids == ["$m8", "$m9", "$m10", "$m11", "$m12"])
    }

    @Test func messagesPageParsing() throws {
        let json = try JSONValue(parsing: #"""
        {"start":"t2","end":"t1","chunk":[{"type":"m.room.message","event_id":"$a","sender":"@u:x","content":{"body":"x"}}],
         "state":[{"type":"m.room.member","state_key":"@u:x","event_id":"$m","content":{"membership":"join"}}]}
        """#)
        let page = try MessagesPage(json: json, roomID: "!r:x")
        #expect(page.events.first?.roomID == "!r:x")
        #expect(page.state.count == 1)
        #expect(page.end == "t1")
        let last = try MessagesPage(json: ["start": "t2", "chunk": []], roomID: "!r:x")
        #expect(last.end == nil)
    }

    @Test func transactionIDsAreUnique() {
        let ids = Set((0..<1000).map { _ in TransactionID.make() })
        #expect(ids.count == 1000)
    }

    @Test func createRoomBodyEnablesEncryption() {
        let body = MatrixClient.CreateRoom(name: "Тест", invite: ["@a:x"]).json
        #expect(body["initial_state"]?.array?.first?["content"]?["algorithm"]?.string == "m.megolm.v1.aes-sha2")
        #expect(body["preset"]?.string == "private_chat")
        #expect(body["invite"]?.array?.count == 1)
    }
}
