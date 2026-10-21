// Чат без звука и участники комнаты.

import Foundation
@testable import NyutagCore
import Testing

@Suite("Без звука и участники")
struct QuietTests {
    let me = "@me:nyutag.chat"

    @Test("без звука = правило комнаты без notify; выключенное и с notify не считаются")
    func mutedFromRules() throws {
        let json = try JSONValue(parsing: #"""
        {"global":{"override":[],"room":[
          {"rule_id":"!quiet:x","default":false,"enabled":true,"actions":[]},
          {"rule_id":"!dont:x","default":false,"enabled":true,"actions":["dont_notify"]},
          {"rule_id":"!loud:x","default":false,"enabled":true,"actions":["notify",{"set_tweak":"sound","value":"default"}]},
          {"rule_id":"!off:x","default":false,"enabled":false,"actions":[]}
        ]}}
        """#)
        #expect(MutedRooms.rooms(json: json) == ["!quiet:x", "!dont:x"])
        #expect(MutedRooms.rooms(json: nil).isEmpty)
    }

    @Test("локальная правка правил: добавить, не задвоить, снять, остальное сохранить")
    func applyKeepsOthers() throws {
        let json = try JSONValue(parsing: #"{"global":{"override":[{"rule_id":"nyutag.ring","actions":["notify"]}],"room":[]}}"#)
        let on = MutedRooms.apply(json: json, roomID: "!a:x", muted: true)
        #expect(MutedRooms.rooms(json: on) == ["!a:x"])
        let twice = MutedRooms.apply(json: on, roomID: "!a:x", muted: true)
        #expect(twice["global"]?["room"]?.array?.count == 1)
        #expect(twice["global"]?["override"]?.array?.count == 1)
        let off = MutedRooms.apply(json: twice, roomID: "!a:x", muted: false)
        #expect(MutedRooms.rooms(json: off).isEmpty)
        #expect(MutedRooms.rooms(json: MutedRooms.apply(json: nil, roomID: "!b:x", muted: true)) == ["!b:x"])
    }

    @Test("без звука: правило на сервере и в базе; снятие удаляет правило, повторное снятие не падает")
    func muteGoesToServer() async throws {
        let server = FakeHomeserver()
        let client = server.client(for: server.session(user: me, device: "D1"))
        let store = try Store.inMemory()
        try await client.setRoomMuted(roomID: "!g:nyutag.chat", true, store: store)
        let rule = try #require(server.pushRule(user: me, kind: "room", id: "!g:nyutag.chat"))
        #expect(rule["actions"]?.array?.isEmpty == true)
        #expect(try await MutedRooms.load(store: store) == ["!g:nyutag.chat"])

        try await client.setRoomMuted(roomID: "!g:nyutag.chat", false, store: store)
        #expect(server.pushRule(user: me, kind: "room", id: "!g:nyutag.chat") == nil)
        #expect(try await MutedRooms.load(store: store).isEmpty)
        try await client.setRoomMuted(roomID: "!g:nyutag.chat", false, store: store)
    }

    @Test("участники: без себя и ушедших, с именем и фото, по алфавиту")
    func membersOfRoom() async throws {
        let store = try Store.inMemory()
        try await store.upsert(RoomRecord(id: "!g", membership: .join))
        let people: [(String, String, String, String?)] = [
            (me, "join", "Я", nil), ("@bair:nyutag.chat", "join", "Баир", "mxc://nyutag.chat/b"),
            ("@dari:nyutag.chat", "invite", "", nil), ("@gone:nyutag.chat", "leave", "Ушёл", nil),
            ("@aldar:nyutag.chat", "join", "Алдар", nil),
        ]
        for (user, membership, name, avatar) in people {
            var content: [String: JSONValue] = ["membership": .string(membership), "displayname": .string(name)]
            if let avatar { content["avatar_url"] = .string(avatar) }
            try await store.setState(Event(eventID: "$m-\(user)", type: EventType.member, sender: user, stateKey: user,
                                           content: .object(content), roomID: "!g"))
        }
        let members = try await People.members(roomID: "!g", store: store, me: me)
        #expect(members.map(\.userID) == ["@aldar:nyutag.chat", "@bair:nyutag.chat", "@dari:nyutag.chat"])
        #expect(members.map(\.name) == ["Алдар", "Баир", "dari"])
        #expect(members[1].avatarURL == "mxc://nyutag.chat/b")
    }

    @Test("знакомые: участники всех вошедших чатов плюс m.direct, без сообществ, без повторов")
    func acquaintances() async throws {
        let store = try Store.inMemory()
        var space = RoomRecord(id: "!space", membership: .join)
        space.isSpace = true
        try await store.upsert(space)
        try await store.upsert(RoomRecord(id: "!g", membership: .join))
        try await store.upsert(RoomRecord(id: "!dm", membership: .join))
        try await store.upsert(RoomRecord(id: "!old", membership: .leave))
        let members: [(String, String, String)] = [
            ("!space", "@stranger:nyutag.chat", "Чужой"), ("!g", "@bair:nyutag.chat", "Баир"), ("!g", me, "Я"),
            ("!dm", "@bair:nyutag.chat", "Баир Д."), ("!dm", me, "Я"), ("!old", "@gone:nyutag.chat", "Ушёл"),
        ]
        for (room, user, name) in members {
            try await store.setState(Event(eventID: "$\(room)-\(user)", type: EventType.member, sender: user, stateKey: user,
                                           content: ["membership": "join", "displayname": .string(name)], roomID: room))
        }
        try await store.setAccountData(EventType.direct, content: ["@bair:nyutag.chat": ["!dm"]])
        let people = try await People.acquaintances(store: store, me: me)
        #expect(people.map(\.userID) == ["@bair:nyutag.chat"])
        #expect(people.first?.name == "Баир Д.")
        #expect(people.first?.directRoom == "!dm")
    }
}
