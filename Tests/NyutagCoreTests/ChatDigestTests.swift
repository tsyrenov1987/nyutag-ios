// Список чатов из базы: заголовки, последняя реплика, галочки, порядок.

import Foundation
import Testing
@testable import NyutagCore

@Suite("Список чатов")
struct ChatDigestTests {
    let me = "@me:nyutag.chat"
    let arjuna = "@arjuna:nyutag.chat"

    func member(_ user: String, _ roomID: String, name: String? = nil, membership: String = "join") -> Event {
        var content: [String: JSONValue] = ["membership": .string(membership)]
        if let name { content["displayname"] = .string(name) }
        return Event(eventID: "$m-\(user)-\(roomID)", type: EventType.member, sender: user, stateKey: user,
                     content: .object(content), roomID: roomID)
    }

    func text(_ id: String, _ roomID: String, from sender: String, ts: Int, _ body: String) -> Event {
        Event(eventID: id, type: EventType.message, sender: sender, originServerTS: ts,
              content: ["msgtype": "m.text", "body": .string(body)], roomID: roomID)
    }

    @Test("личный чат без имени называется по собеседнику, реакция не перекрывает реплику")
    func directTitleAndPreview() async throws {
        let store = try Store.inMemory()
        var room = RoomRecord(id: "!dm", membership: .join)
        room.isDirect = true
        room.heroes = [arjuna]
        room.notificationCount = 2
        try await store.upsert(room)
        for event in [member(me, "!dm", name: "Я"), member(arjuna, "!dm", name: "Арюна")] { try await store.setState(event) }
        try await store.append([
            text("$1", "!dm", from: arjuna, ts: 100, "Сайн байна!"),
            Event(eventID: "$2", type: EventType.reaction, sender: me, originServerTS: 110,
                  content: ["m.relates_to": ["rel_type": "m.annotation", "event_id": "$1", "key": "👍"]], roomID: "!dm"),
        ])
        let lines = try await ChatDigest.lines(store: store, me: me)
        let line = try #require(lines.first)
        #expect(line.title == "Арюна")
        #expect(line.last == .text("Сайн байна!"))
        #expect(line.lastSenderName == "Арюна")
        #expect(!line.lastIsMine)
        #expect(line.delivery == .none)
        #expect(line.lastTS == 100)
        #expect(line.unread == 2)
    }

    @Test("своя реплика: одна галочка, после отметки прочтения собеседником — две")
    func deliveryTicks() async throws {
        let store = try Store.inMemory()
        try await store.upsert(RoomRecord(id: "!dm", membership: .join))
        for event in [member(me, "!dm"), member(arjuna, "!dm")] { try await store.setState(event) }
        try await store.append([text("$1", "!dm", from: arjuna, ts: 100, "привет"), text("$2", "!dm", from: me, ts: 200, "здарова")])
        #expect(try await ChatDigest.lines(store: store, me: me).first?.delivery == .sent)
        // Отметка на более раннем событии ещё не значит прочтения.
        try await store.setReceipt(roomID: "!dm", userID: arjuna, eventID: "$1", ts: 150)
        #expect(try await ChatDigest.lines(store: store, me: me).first?.delivery == .sent)
        // Своя отметка не считается.
        try await store.setReceipt(roomID: "!dm", userID: me, eventID: "$2", ts: 210)
        #expect(try await ChatDigest.lines(store: store, me: me).first?.delivery == .sent)
        try await store.setReceipt(roomID: "!dm", userID: arjuna, eventID: "$2", ts: 220)
        let line = try #require(try await ChatDigest.lines(store: store, me: me).first)
        #expect(line.delivery == .read)
        #expect(line.lastIsMine)
    }

    @Test("зашифрованное: без ключа — замок, с расшифровкой — текст; правка не становится последней")
    func encryptedAndEdits() async throws {
        let store = try Store.inMemory()
        try await store.upsert(RoomRecord(id: "!e", membership: .join))
        let sealed = Event(eventID: "$s", type: EventType.encrypted, sender: arjuna, originServerTS: 300,
                           content: ["algorithm": "m.megolm.v1.aes-sha2"], roomID: "!e")
        let edit = Event(eventID: "$x", type: EventType.message, sender: arjuna, originServerTS: 310,
                         content: ["msgtype": "m.text", "body": "* правка",
                                   "m.relates_to": ["rel_type": "m.replace", "event_id": "$s"]], roomID: "!e")
        try await store.append([sealed, edit])
        #expect(try await ChatDigest.lines(store: store, me: me).first?.last == .locked)

        let lines = try await ChatDigest.lines(store: store, me: me) { event, roomID in
            Event(eventID: event.eventID, type: EventType.message, sender: event.sender,
                  originServerTS: event.originServerTS, content: ["msgtype": "m.image", "body": "фото.jpg"], roomID: roomID)
        }
        #expect(lines.first?.last == .image)
        #expect(lines.first?.lastTS == 300)
    }

    @Test("порядок: приглашения сверху, дальше свежие; покинутые скрыты; группа без имени — по участникам")
    func orderingAndTitles() async throws {
        let store = try Store.inMemory()
        var old = RoomRecord(id: "!old", membership: .join)
        old.name = "Старый"
        var fresh = RoomRecord(id: "!fresh", membership: .join)
        fresh.canonicalAlias = "#hori:nyutag.chat"
        let invite = RoomRecord(id: "!inv", membership: .invite)
        let left = RoomRecord(id: "!left", membership: .leave)
        let group = RoomRecord(id: "!grp", membership: .join)
        for room in [old, fresh, invite, left, group] { try await store.upsert(room) }
        try await store.append([text("$o", "!old", from: arjuna, ts: 10, "a"), text("$f", "!fresh", from: arjuna, ts: 20, "b")])
        for event in [member(me, "!grp"), member("@bair:nyutag.chat", "!grp", name: "Баир"), member("@dasha:nyutag.chat", "!grp"),
                      member("@gone:nyutag.chat", "!grp", membership: "leave")] {
            try await store.setState(event)
        }
        let lines = try await ChatDigest.lines(store: store, me: me)
        #expect(lines.map(\.id) == ["!inv", "!fresh", "!old", "!grp"])
        #expect(lines[1].title == "#hori:nyutag.chat")
        #expect(lines[2].title == "Старый")
        #expect(lines[3].title == "Баир, dasha")
        #expect(lines[3].last == nil)
        #expect(lines[0].title == "")
    }

    @Test func localpart() {
        #expect(ChatDigest.localpart("@arjuna:nyutag.chat") == "arjuna")
        #expect(ChatDigest.localpart("bare") == "bare")
    }

    @Test("старое приглашение в чате, куда уже вошли, не показывается последней репликой")
    func staleInvite() async throws {
        let store = try Store.inMemory()
        try await store.upsert(RoomRecord(id: "!g", membership: .join))
        try await store.append([member(me, "!g", membership: "invite")])
        let line = try #require(try await ChatDigest.lines(store: store, me: me).first)
        #expect(line.last == nil)
    }
}
