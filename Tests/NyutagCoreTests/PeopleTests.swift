// Вкладка «Контакты»: номера в виде сервера, кто в Нютаге и кого позвать, поиск по имени, нику и номеру.

import Testing
@testable import NyutagCore

@Suite("Контакты")
struct PeopleTests {
    @Test("номер приводится к виду сервера")
    func phoneKey() {
        #expect(People.phoneKey("8 (912) 345-67-89") == "+79123456789")
        #expect(People.phoneKey("9123456789") == "+79123456789")
        #expect(People.phoneKey("+7 912 345 67 89") == "+79123456789")
        #expect(People.phoneKey("+976 9911 2233") == "+97699112233")
        #expect(People.phoneKey("112") == nil)
    }

    @Test("одинаковые номера на сверку уходят один раз")
    func unique() {
        let book = [BookEntry(id: "1", name: "Аня", phones: ["8 912 345-67-89", "+79123456789"]),
                    BookEntry(id: "2", name: "Баир", phones: ["9123456789", "+7 900 000 00 01"])]
        #expect(People.uniquePhones(book) == ["8 912 345-67-89", "+7 900 000 00 01"])
    }

    @Test("найденные по номеру — в Нютаге с именем из книжки, остальных можно позвать")
    func merge() {
        let book = [BookEntry(id: "1", name: "Сэсэг", phones: ["8 912 345-67-89"]),
                    BookEntry(id: "2", name: "Арюна", phones: ["+7 900 000 00 01"]),
                    BookEntry(id: "3", name: "Баир", phones: ["+7 900 000 00 02"])]
        let known = [Person(userID: "@sesegma:nyutag.chat", name: "sesegma", directRoom: "!a"),
                     Person(userID: "@tumen:nyutag.chat", name: "Түмэн", directRoom: "!b")]
        let (inNyutag, invite) = People.merge(book: book, matches: ["+79123456789": "@sesegma:nyutag.chat",
                                                                     "+7 900 000 00 01": "@aryuna:nyutag.chat"],
                                              known: known)
        #expect(inNyutag.map(\.name) == ["Арюна", "Сэсэг", "Түмэн"])
        #expect(inNyutag.first { $0.userID == "@sesegma:nyutag.chat" }?.directRoom == "!a")
        #expect(inNyutag.first { $0.userID == "@aryuna:nyutag.chat" }?.directRoom == nil)
        #expect(invite.map(\.name) == ["Баир"])
    }

    @Test("поиск по имени, нику и цифрам номера")
    func search() {
        #expect(People.matches("сэс", name: "Сэсэг"))
        #expect(People.matches("@sese", name: "Сэсэг", userID: "@sesegma:nyutag.chat"))
        #expect(People.matches("8 912 345", name: "Сэсэг", phones: ["+7 912 345-67-89"]))
        #expect(People.matches("89123456789", name: "Сэсэг", phones: ["+7 912 345-67-89"]))
        #expect(!People.matches("12", name: "Сэсэг", phones: ["+7 912 345-67-89"]))
        #expect(!People.matches("баир", name: "Сэсэг"))
        #expect(People.matches("  ", name: "Сэсэг"))
    }

    @Test("собеседники берутся из m.direct с именем участника")
    func known() async throws {
        let store = try Store.inMemory()
        var room = RoomRecord(id: "!a", membership: .join)
        room.isDirect = true
        try await store.upsert(room)
        try await store.setAccountData(EventType.direct, content: ["@sesegma:nyutag.chat": ["!a"], "@gone:nyutag.chat": ["!x"]])
        try await store.setState(#require(Event(json: ["type": "m.room.member", "state_key": "@sesegma:nyutag.chat",
                                              "room_id": "!a", "sender": "@sesegma:nyutag.chat",
                                              "content": ["membership": "join", "displayname": "Сэсэгма"]])))
        let people = try await People.known(store: store, me: "@me:nyutag.chat")
        #expect(people == [Person(userID: "@sesegma:nyutag.chat", name: "Сэсэгма", directRoom: "!a")])
    }

    @Test("собеседник: из m.direct, иначе второй участник комнаты на двоих")
    func partner() async throws {
        let store = try Store.inMemory()
        try await store.setAccountData(EventType.direct, content: ["@sesegma:nyutag.chat": ["!a"]])
        func member(_ room: String, _ user: String, _ membership: String = "join") throws -> Event {
            try #require(Event(json: ["type": "m.room.member", "state_key": .string(user), "room_id": .string(room),
                                      "sender": .string(user), "content": ["membership": .string(membership)]]))
        }
        for event in [try member("!b", "@me:nyutag.chat"), try member("!b", "@bair:nyutag.chat"),
                      try member("!c", "@me:nyutag.chat"), try member("!c", "@bair:nyutag.chat"),
                      try member("!c", "@dulma:nyutag.chat"), try member("!d", "@me:nyutag.chat"),
                      try member("!d", "@dulma:nyutag.chat"), try member("!d", "@bair:nyutag.chat", "leave")] {
            try await store.setState(event)
        }
        let me = "@me:nyutag.chat"
        #expect(try await People.partner(roomID: "!a", store: store, me: me) == "@sesegma:nyutag.chat")
        #expect(try await People.partner(roomID: "!b", store: store, me: me) == "@bair:nyutag.chat")
        #expect(try await People.partner(roomID: "!c", store: store, me: me) == nil)
        #expect(try await People.partner(roomID: "!d", store: store, me: me) == "@dulma:nyutag.chat")
    }
}
