import Foundation
@testable import NyutagCore
import Testing

@Suite struct StoreTests {
    @Test func sqliteBasics() throws {
        let db = try SQLite.inMemory()
        try db.exec("CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT, blob BLOB, real REAL)")
        try db.run("INSERT INTO t(name, blob, real) VALUES(?, ?, ?)", .text("юрта"), .blob(Data([1, 2, 3])), .real(1.5))
        try db.run("INSERT INTO t(name) VALUES(?)", .null)
        let rows = try db.query("SELECT id, name, blob, real FROM t ORDER BY id") { row in
            (row.int(0), row.string(1), row.data(2), row.value(3).double)
        }
        #expect(rows.count == 2)
        #expect(rows[0].1 == "юрта")
        #expect(rows[0].2 == Data([1, 2, 3]))
        #expect(rows[0].3 == 1.5)
        #expect(rows[1].1 == nil)
        #expect(try db.scalar("SELECT COUNT(*) FROM t")?.int == 2)
    }

    @Test func transactionRollsBack() throws {
        let db = try SQLite.inMemory()
        try db.exec("CREATE TABLE t(x INTEGER)")
        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try db.transaction {
                try db.run("INSERT INTO t VALUES(1)")
                throw Boom()
            }
        }
        #expect(try db.scalar("SELECT COUNT(*) FROM t")?.int == 0)
    }

    @Test func storeRoomsEventsState() async throws {
        let store = try Store.inMemory()
        var room = RoomRecord(id: "!a:nyutag.chat", membership: .join)
        room.name = "Улан-Удэ"
        room.isEncrypted = true
        try await store.upsert(room)
        #expect(try await store.room("!a:nyutag.chat")?.name == "Улан-Удэ")
        #expect(try await store.rooms(membership: .join).count == 1)

        let events = (1...3).map { i in
            Event(eventID: "$e\(i)", type: EventType.message, sender: "@u:nyutag.chat", originServerTS: 1000 + i,
                  content: ["msgtype": "m.text", "body": .string("сообщение \(i)")], roomID: "!a:nyutag.chat")
        }
        try await store.append(events)
        try await store.append([events[1]]) // дубликат
        #expect(try await store.eventCount(in: "!a:nyutag.chat") == 3)
        let loaded = try await store.events(in: "!a:nyutag.chat", limit: 2)
        #expect(loaded.map(\.eventID) == ["$e2", "$e3"])
        #expect(loaded[0].content["body"]?.string == "сообщение 2")

        let name = Event(eventID: "$s1", type: EventType.name, sender: "@u:nyutag.chat", stateKey: "",
                         content: ["name": "Нютаг"], roomID: "!a:nyutag.chat")
        try await store.setState(name)
        #expect(try await store.state("!a:nyutag.chat", type: EventType.name)?["name"]?.string == "Нютаг")

        try await store.setAccountData(EventType.chatLayout, content: ["pins": ["!a:nyutag.chat"]])
        #expect(try await store.accountData(EventType.chatLayout)?["pins"]?[0]?.string == "!a:nyutag.chat")

        try await store.setMeta("sync_token", "s1")
        #expect(try await store.syncToken == "s1")
        try await store.wipe()
        #expect(try await store.syncToken == nil)
        #expect(try await store.rooms().isEmpty)
    }
}
