// Блокировка, жалоба, удаление аккаунта.

import Foundation
@testable import NyutagCore
import Testing

@Suite("Защита от людей")
struct SafetyTests {
    let me = "@me:nyutag.chat"
    let bully = "@bully:nyutag.chat"

    @Test("список блокированных: формат m.ignored_user_list, чужие ключи не считаются")
    func ignoredFormat() throws {
        let json = try JSONValue(parsing: #"{"ignored_users":{"@bully:nyutag.chat":{},"@spam:x":{"why":1},"junk":{}}}"#)
        #expect(IgnoredUsers.users(json: json) == [bully, "@spam:x"])
        #expect(IgnoredUsers.users(json: nil).isEmpty)
        #expect(IgnoredUsers.users(json: try JSONValue(parsing: #"{"ignored_users":[]}"#)).isEmpty)
        let back = IgnoredUsers.json(users: [bully])
        #expect(back["ignored_users"]?[bully] == .object([:]))
        #expect(IgnoredUsers.users(json: back) == [bully])
    }

    @Test("блокировка уходит на сервер и в базу; лента и список чатов прячут реплики блокированного")
    func blockHidesMessages() async throws {
        let server = FakeHomeserver()
        let session = server.session(user: me, device: "D1")
        let client = server.client(for: session)
        let store = try Store.inMemory()
        try await store.upsert(RoomRecord(id: "!dm", membership: .join))
        for user in [me, bully] {
            try await store.setState(Event(eventID: "$m-\(user)", type: EventType.member, sender: user, stateKey: user,
                                           content: ["membership": "join", "displayname": .string(ChatDigest.localpart(user))],
                                           roomID: "!dm"))
        }
        try await store.append([
            Event(eventID: "$1", type: EventType.message, sender: me, originServerTS: 100,
                  content: ["msgtype": "m.text", "body": "привет"], roomID: "!dm"),
            Event(eventID: "$2", type: EventType.message, sender: bully, originServerTS: 200,
                  content: ["msgtype": "m.text", "body": "гадость"], roomID: "!dm"),
            Event(eventID: "$3", type: EventType.reaction, sender: bully, originServerTS: 210,
                  content: ["m.relates_to": ["rel_type": "m.annotation", "event_id": "$1", "key": "💩"]], roomID: "!dm"),
        ])
        #expect(try await ChatFeed.items(roomID: "!dm", store: store, me: me).map(\.id) == ["$1", "$2"])
        #expect(try await ChatDigest.lines(store: store, me: me).first?.last == .text("гадость"))

        try await client.setIgnoredUsers([bully], userID: me, store: store)
        #expect(IgnoredUsers.users(json: server.accountDataContent(user: me, type: EventType.ignoredUsers)) == [bully])
        let ignored = try await IgnoredUsers.load(store: store)
        #expect(ignored == [bully])
        let items = try await ChatFeed.items(roomID: "!dm", store: store, me: me, ignored: ignored)
        #expect(items.map(\.id) == ["$1"])
        #expect(items.first?.reactions.isEmpty == true)
        let line = try #require(try await ChatDigest.lines(store: store, me: me, ignored: ignored).first)
        #expect(line.last == .text("привет"))
        #expect(line.lastIsMine)

        try await client.setIgnoredUsers([], userID: me, store: store)
        #expect(try await IgnoredUsers.load(store: store).isEmpty)
    }

    @Test("жалоба уходит на сервер с причиной")
    func reportGoesToServer() async throws {
        let server = FakeHomeserver()
        let client = server.client(for: server.session(user: me, device: "D1"))
        try await client.report(roomID: "!dm", eventID: "$2", reason: "оскорбления")
        let report = try #require(server.reports.first)
        #expect(report.user == me)
        #expect(report.roomID == "!dm")
        #expect(report.eventID == "$2")
        #expect(report.reason == "оскорбления")
        #expect(report.score == -100)
    }

    @Test("удаление аккаунта: подтверждение паролем, неверный пароль отказ, после удаления токен мёртв")
    func deactivateWithPassword() async throws {
        let server = FakeHomeserver()
        server.setPassword("секрет", user: me)
        let session = server.session(user: me, device: "D1")
        let client = server.client(for: session)
        await #expect(throws: MatrixError.self) {
            try await client.deactivate(userID: me, password: "не тот")
        }
        #expect(server.deactivated.isEmpty)
        #expect(server.isTokenValid(session.accessToken))

        try await client.deactivate(userID: me, password: "секрет")
        #expect(server.deactivated == [me])
        #expect(server.erased)
        #expect(!server.isTokenValid(session.accessToken))
    }
}
