// Лента чата из базы: правки, удаления, реакции, ответы, служебные плашки, прочтение своих реплик.

import Foundation
import Testing
@testable import NyutagCore

@Suite("Лента чата")
struct ChatFeedTests {
    let me = "@me:nyutag.chat"
    let arjuna = "@arjuna:nyutag.chat"
    let room = "!r"

    func member(_ user: String, name: String? = nil, membership: String = "join", by sender: String? = nil,
                id: String? = nil, ts: Int = 0, before: JSONValue? = nil) -> Event {
        var content: [String: JSONValue] = ["membership": .string(membership)]
        if let name { content["displayname"] = .string(name) }
        return Event(eventID: id ?? "$m-\(user)", type: EventType.member, sender: sender ?? user, originServerTS: ts,
                     stateKey: user, content: .object(content),
                     unsigned: before.map { ["prev_content": $0] }, roomID: room)
    }

    func text(_ id: String, from sender: String, ts: Int, _ body: String, extra: [String: JSONValue] = [:]) -> Event {
        var content: [String: JSONValue] = ["msgtype": "m.text", "body": .string(body)]
        for (key, value) in extra { content[key] = value }
        return Event(eventID: id, type: EventType.message, sender: sender, originServerTS: ts, content: .object(content), roomID: room)
    }

    func prepared(encrypted: Bool = true) async throws -> Store {
        let store = try Store.inMemory()
        var record = RoomRecord(id: room, membership: .join)
        record.isEncrypted = encrypted
        try await store.upsert(record)
        for event in [member(me, name: "Я"), member(arjuna, name: "Арюна")] { try await store.setState(event) }
        return store
    }

    @Test("правка подставляется в реплику, чужая правка не принимается, сама правка в ленту не попадает")
    func edits() async throws {
        let store = try await prepared()
        try await store.append([
            text("$1", from: arjuna, ts: 100, "сайн"),
            text("$2", from: arjuna, ts: 110, "* сайн байна", extra: [
                "m.new_content": ["msgtype": "m.text", "body": "сайн байна"],
                "m.relates_to": ["rel_type": "m.replace", "event_id": "$1"],
            ]),
            text("$3", from: me, ts: 120, "моё"),
            text("$4", from: arjuna, ts: 130, "* чужая правка", extra: [
                "m.new_content": ["msgtype": "m.text", "body": "подмена"],
                "m.relates_to": ["rel_type": "m.replace", "event_id": "$3"],
            ]),
        ])
        let items = try await ChatFeed.items(roomID: room, store: store, me: me)
        #expect(items.map(\.id) == ["$1", "$3"])
        let first = try #require(items.first { $0.id == "$1" })
        #expect(first.body == .text("сайн байна"))
        #expect(first.edited)
        #expect(first.senderName == "Арюна")
        let mine = try #require(items.first { $0.id == "$3" })
        #expect(mine.body == .text("моё"))
        #expect(!mine.edited)
        #expect(mine.isMine)
    }

    @Test("реакции считаются по ключу, удалённая реплика без текста и реакций, удаление само не видно")
    func reactionsAndRedactions() async throws {
        let store = try await prepared()
        func react(_ id: String, _ sender: String, _ key: String, on target: String) -> Event {
            Event(eventID: id, type: EventType.reaction, sender: sender, originServerTS: 200,
                  content: ["m.relates_to": ["rel_type": "m.annotation", "event_id": .string(target), "key": .string(key)]],
                  roomID: room)
        }
        try await store.append([
            text("$1", from: arjuna, ts: 100, "хурдан"),
            text("$2", from: arjuna, ts: 101, "удалю"),
            react("$r1", me, "👍", on: "$1"),
            react("$r2", arjuna, "👍", on: "$1"),
            react("$r3", arjuna, "🔥", on: "$1"),
            react("$r4", me, "👍", on: "$2"),
            Event(eventID: "$x", type: EventType.redaction, sender: arjuna, originServerTS: 300,
                  content: ["redacts": "$2"], roomID: room),
        ])
        let items = try await ChatFeed.items(roomID: room, store: store, me: me)
        let first = try #require(items.first { $0.id == "$1" })
        #expect(first.reactions == [.init(key: "👍", count: 2, mine: true, myEventID: "$r1"),
                                    .init(key: "🔥", count: 1, mine: false)])
        let gone = try #require(items.first { $0.id == "$2" })
        #expect(gone.body == .deleted)
        #expect(gone.reactions.isEmpty)
        #expect(!items.contains { $0.id == "$x" || $0.id.hasPrefix("$r") })
    }

    @Test("снятая реакция не считается; своя правка из Relations подставляется; править и удалять можно только своё")
    func ownActions() async throws {
        let store = try await prepared()
        try await store.append([
            text("$1", from: me, ts: 100, "сайн"),
            text("$2", from: arjuna, ts: 101, "байна"),
            Event(eventID: "$r1", type: EventType.reaction, sender: me, originServerTS: 102,
                  content: Relations.reaction(to: "$2", key: "❤️"), roomID: room),
            Event(eventID: "$e1", type: EventType.message, sender: me, originServerTS: 103,
                  content: Relations.edit(of: "$1", text: "сайн байна"), roomID: room),
            Event(eventID: "$x", type: EventType.redaction, sender: me, originServerTS: 104,
                  content: ["redacts": "$r1"], roomID: room),
        ])
        let items = try await ChatFeed.items(roomID: room, store: store, me: me)
        #expect(items.map(\.id) == ["$1", "$2"])
        #expect(items[0].body == .text("сайн байна"))
        #expect(items[0].edited && items[0].canEdit && items[0].canDelete)
        #expect(!items[1].canEdit && !items[1].canDelete)
        #expect(items[1].reactions.isEmpty)
    }

    @Test("кто набирает: последний m.typing без себя, без него — нет новостей")
    func typing() {
        let events = [Event(type: EventType.typing, content: ["user_ids": [.string(me), .string(arjuna)]], roomID: room)]
        #expect(Relations.typing(events, me: me) == [arjuna])
        #expect(Relations.typing([], me: me) == nil)
    }

    @Test("кто в сети: online с currently_active, иначе когда был по last_active_ago")
    func presence() {
        let now = Date(timeIntervalSince1970: 1_000)
        let events = [
            Event(type: EventType.presence, sender: arjuna,
                  content: ["presence": "online", "currently_active": true, "last_active_ago": 0]),
            Event(type: EventType.presence, sender: me, content: ["presence": "offline", "last_active_ago": 60_000]),
        ]
        let seen = Relations.presence(events, now: now)
        #expect(seen[arjuna] == Relations.Presence(online: true, lastActive: now))
        #expect(seen[me] == Relations.Presence(online: false, lastActive: now.addingTimeInterval(-60)))
        #expect(Relations.presence([]).isEmpty)
    }

    @Test("ответ несёт цитату; без ключа — замок; с расшифровкой — текст")
    func repliesAndEncryption() async throws {
        let store = try await prepared()
        let sealed = Event(eventID: "$s", type: EventType.encrypted, sender: arjuna, originServerTS: 100,
                           content: ["algorithm": "m.megolm.v1.aes-sha2"], roomID: room)
        try await store.append([
            sealed,
            text("$a", from: me, ts: 110, "> <@arjuna> ...\n\nответ", extra: [
                "m.relates_to": ["m.in_reply_to": ["event_id": "$s"]],
            ]),
        ])
        let locked = try await ChatFeed.items(roomID: room, store: store, me: me)
        #expect(locked.first { $0.id == "$s" }?.body == .locked)
        #expect(locked.first { $0.id == "$a" }?.reply?.preview == .locked)

        let room = room
        let opened = try await ChatFeed.items(roomID: room, store: store, me: me) { event, _ in
            guard event.eventID == "$s" else { return nil }
            return Event(eventID: "$s", type: EventType.message, sender: event.sender, originServerTS: 100,
                         content: ["msgtype": "m.text", "body": "тайна"], roomID: room)
        }
        #expect(opened.first { $0.id == "$s" }?.body == .text("тайна"))
        let answer = try #require(opened.first { $0.id == "$a" })
        #expect(answer.body == .text("ответ"))
        #expect(answer.reply == .init(eventID: "$s", senderName: "Арюна", preview: .text("тайна")))
    }

    @Test("в открытой группе нерасшифрованное — сигнал звонка: в ленту не попадает")
    func openRoomHidesSealed() async throws {
        let store = try await prepared(encrypted: false)
        try await store.append([
            text("$1", from: arjuna, ts: 100, "сайн"),
            Event(eventID: "$s", type: EventType.encrypted, sender: arjuna, originServerTS: 110,
                  content: ["algorithm": "m.megolm.v1.aes-sha2"], roomID: room),
        ])
        #expect(try await ChatFeed.items(roomID: room, store: store, me: me).map(\.id) == ["$1"])
    }

    @Test("нерасшифрованное до нашего входа — одной плашкой, после входа — как есть")
    func lockedBeforeJoin() async throws {
        let store = try await prepared()
        func sealed(_ id: String, ts: Int) -> Event {
            Event(eventID: id, type: EventType.encrypted, sender: arjuna, originServerTS: ts,
                  content: ["algorithm": "m.megolm.v1.aes-sha2"], roomID: room)
        }
        try await store.append([
            text("$0", from: arjuna, ts: 90, "открыто"),
            sealed("$s1", ts: 100), sealed("$s2", ts: 101),
            member(me, name: "Я", id: "$own", ts: 110),
            sealed("$s3", ts: 120),
        ])
        let items = try await ChatFeed.items(roomID: room, store: store, me: me)
        #expect(items.map(\.id) == ["$0", "$s1", "$own", "$s3"])
        #expect(items[1].body == .notice(.earlierLocked))
        #expect(items[3].body == .locked)

        // Ключ всё же пришёл (например, из резервной копии) — реплика видна.
        let roomID = room
        let opened = try await ChatFeed.items(roomID: roomID, store: store, me: me) { event, _ in
            guard event.eventID == "$s2" else { return nil }
            return Event(eventID: "$s2", type: EventType.message, sender: event.sender, originServerTS: 101,
                         content: ["msgtype": "m.text", "body": "тайна"], roomID: roomID)
        }
        #expect(opened.first { $0.id == "$s2" }?.body == .text("тайна"))
        #expect(opened.first { $0.id == "$s1" }?.body == .notice(.earlierLocked))
    }

    @Test("цитата в ответе показывает текст после правки")
    func replyQuotesEditedText() async throws {
        let store = try await prepared()
        try await store.append([
            text("$1", from: arjuna, ts: 100, "сайн"),
            Event(eventID: "$e", type: EventType.message, sender: arjuna, originServerTS: 101,
                  content: Relations.edit(of: "$1", text: "сайн байна"), roomID: room),
            text("$a", from: me, ts: 110, "ответ", extra: [
                "m.relates_to": ["m.in_reply_to": ["event_id": "$1"]],
            ]),
        ])
        let items = try await ChatFeed.items(roomID: room, store: store, me: me)
        #expect(items.first { $0.id == "$a" }?.reply?.preview == .text("сайн байна"))

        // Удалённый ответ цитату не несёт.
        try await store.append([Event(eventID: "$x", type: EventType.redaction, sender: me, originServerTS: 120,
                                      content: ["redacts": "$a"], roomID: room)])
        #expect(try await ChatFeed.items(roomID: room, store: store, me: me).first { $0.id == "$a" }?.reply == nil)
    }

    @Test("служебные плашки: создание, вход, приглашение, смена имени, исключение, шифрование")
    func notices() async throws {
        let store = try await prepared()
        let joined: JSONValue = ["membership": "join", "displayname": "Арюна"]
        try await store.append([
            Event(eventID: "$c", type: EventType.create, sender: me, originServerTS: 1, stateKey: "", content: [:], roomID: room),
            member(me, name: "Я", id: "$own", ts: 1),
            Event(eventID: "$e", type: EventType.encryption, sender: me, originServerTS: 2, stateKey: "",
                  content: ["algorithm": "m.megolm.v1.aes-sha2"], roomID: room),
            member(arjuna, name: "Арюна", membership: "invite", by: me, id: "$i", ts: 3),
            member(arjuna, name: "Арюна", id: "$j", ts: 4, before: ["membership": "invite"]),
            member(arjuna, name: "Арюна Д.", id: "$n", ts: 5, before: joined),
            member(arjuna, id: "$same", ts: 6, before: ["membership": "join", "displayname": "Арюна Д."]),
            member(arjuna, membership: "leave", by: me, id: "$k", ts: 7, before: ["membership": "join", "displayname": "Арюна Д."]),
        ])
        let items = try await ChatFeed.items(roomID: room, store: store, me: me)
        let notices = items.compactMap { item -> FeedItem.Notice? in if case .notice(let n) = item.body { n } else { nil } }
        #expect(notices == [
            .created(by: "Я"), .encryptionOn(by: "Я"), .invited("Арюна", by: "Я"), .joined("Арюна"),
            .renamedSelf(from: "Арюна", to: "Арюна Д."), .removed("Арюна Д.", by: "Я"),
        ])
    }

    @Test("своя реплика прочитана, если собеседник отметил её или более позднюю")
    func readMarks() async throws {
        let store = try await prepared()
        try await store.append([
            text("$1", from: me, ts: 100, "раз"),
            text("$2", from: arjuna, ts: 200, "два"),
            text("$3", from: me, ts: 300, "три"),
        ])
        try await store.setReceipt(roomID: room, userID: arjuna, eventID: "$2", ts: 250)
        let items = try await ChatFeed.items(roomID: room, store: store, me: me)
        #expect(items.first { $0.id == "$1" }?.isRead == true)
        #expect(items.first { $0.id == "$2" }?.isRead == false)
        #expect(items.first { $0.id == "$3" }?.isRead == false)
    }

    @Test("вложение: вид и подпись отдельно от имени файла")
    func attachments() async throws {
        let store = try await prepared()
        try await store.append([
            Event(eventID: "$p", type: EventType.message, sender: arjuna, originServerTS: 1,
                  content: ["msgtype": "m.image", "body": "IMG_1.jpg", "url": "mxc://x/y"], roomID: room),
            Event(eventID: "$q", type: EventType.message, sender: arjuna, originServerTS: 2,
                  content: ["msgtype": "m.image", "body": "Байкал", "filename": "IMG_2.jpg", "url": "mxc://x/z"], roomID: room),
        ])
        let items = try await ChatFeed.items(roomID: room, store: store, me: me)
        #expect(items.first { $0.id == "$p" }?.body == .attachment(.image, caption: nil))
        #expect(items.first { $0.id == "$q" }?.body == .attachment(.image, caption: "Байкал"))
        #expect(items.first { $0.id == "$q" }?.attachment?.name == "IMG_2.jpg")
        #expect(items.first { $0.id == "$q" }?.attachment?.source == .plain(MXC("mxc://x/z")!))
    }
}
