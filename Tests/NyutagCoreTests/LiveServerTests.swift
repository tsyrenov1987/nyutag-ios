// Живой тест против ядра nyutag.chat. Запускается только при заданных переменных окружения
// (`tools/test-env.sh`): NYUTAG_TEST_HS (адрес Tuwunel), NYUTAG_TEST_USER, NYUTAG_TEST_PASSWORD; для релея звонков
// — дверь NYUTAG_TEST_DOOR и ключ NYUTAG_TEST_DOOR_KEY (как у приложения, без SSH).

import Foundation
@testable import NyutagCore
import Testing

enum LiveEnv {
    static let homeserver = ProcessInfo.processInfo.environment["NYUTAG_TEST_HS"].flatMap(URL.init(string:))
    static let user = ProcessInfo.processInfo.environment["NYUTAG_TEST_USER"]
    static let password = ProcessInfo.processInfo.environment["NYUTAG_TEST_PASSWORD"]
    static let api = ProcessInfo.processInfo.environment["NYUTAG_TEST_API"].flatMap(URL.init(string:))
    static let door = ProcessInfo.processInfo.environment["NYUTAG_TEST_DOOR"].flatMap(URL.init(string:))
        .flatMap { Door(url: $0, name: "test") }
    static let doorKey = ProcessInfo.processInfo.environment["NYUTAG_TEST_DOOR_KEY"]
    static var doorAvailable: Bool { door != nil && doorKey != nil }
    /// Клиент к ядру через дверь, как в приложении.
    static func doorClient(accessToken: String?) -> MatrixClient {
        MatrixClient(homeserver: URL(string: "https://core.nyutag.chat")!, accessToken: accessToken,
                     doorKey: doorKey, door: door, doorWait: .zero)
    }
    static var available: Bool { homeserver != nil && user != nil && password != nil }
}

@Suite(.enabled(if: LiveEnv.available, "нет NYUTAG_TEST_HS/USER/PASSWORD")) struct LiveServerTests {
    @Test func versionsLoginSyncRoomsLogout() async throws {
        let client = MatrixClient(homeserver: LiveEnv.homeserver!)
        let versions: JSONValue = try await client.raw(.get, "/_matrix/client/versions", authenticated: false)
        #expect(versions["versions"]?.array?.contains("v1.11") == true)

        let session = try await client.login(user: LiveEnv.user!, password: LiveEnv.password!,
                                             deviceDisplayName: "Нютаг тест (Мак)")
        #expect(session.userID.hasPrefix("@"))
        #expect(session.serverName == "nyutag.chat")
        #expect(!session.deviceID.isEmpty)

        let me = try await client.whoAmI()
        #expect(me.userID == session.userID)
        #expect(me.deviceID == session.deviceID)

        let store = try Store.inMemory()
        let engine = SyncEngine(client: client, store: store, session: session)
        let first = try await engine.syncOnce()
        #expect(first.isInitial)
        let rooms = try await store.rooms()
        #expect(!rooms.isEmpty, "у тестовой учётки должны быть комнаты")
        let joined = rooms.filter { $0.membership == .join }
        print("live sync: \(rooms.count) комнат, \(joined.count) joined, \(first.response.toDevice.count) to-device, otk=\(first.response.oneTimeKeysCount)")
        for room in joined.prefix(5) {
            let count = try await store.eventCount(in: room.id)
            print("  \(room.id) name=\(room.name ?? "-") encrypted=\(room.isEncrypted) events=\(count) joined=\(room.joinedCount)")
        }
        #expect(try await store.syncToken != nil)

        // Инкрементальный sync с нулевым ожиданием возвращает новый маркер и ничего не ломает.
        let second = try await engine.syncOnce()
        #expect(!second.isInitial)

        try await roomLifecycle(client: client, session: session)
        try await media(client: client)
        try await nyutagInvites(client: client)

        try await client.logout()
        await #expect(throws: MatrixError.self) { try await client.whoAmI() }
    }

    /// Комната целиком: создать, назвать, написать, удалить сообщение, докачать историю, прочитать, выйти и забыть.
    /// Вызывается из основного теста в той же сессии: ядро режет частые входы одной учётки (429).
    private func roomLifecycle(client: MatrixClient, session: Session) async throws {
        let roomID = try await client.createRoom(.init(name: "нютаг-тест \(TransactionID.make())", encrypted: false))
        var sent: [String] = []
        for i in 1...25 { sent.append(try await client.sendText(roomID: roomID, "сообщение \(i)")) }
        try await client.setState(roomID: roomID, type: EventType.topic, content: ["topic": "тема из теста"])
        let redaction = try await client.redact(roomID: roomID, eventID: sent[0], reason: "тест")
        #expect(redaction.hasPrefix("$"))
        // Повтор с тем же txn не плодит событие.
        let txn = TransactionID.make()
        let a = try await client.send(roomID: roomID, type: EventType.message, content: ["msgtype": "m.text", "body": "раз"], transactionID: txn)
        let b = try await client.send(roomID: roomID, type: EventType.message, content: ["msgtype": "m.text", "body": "раз"], transactionID: txn)
        #expect(a == b)

        // Свежее хранилище: начальный sync берёт хвост в 20 событий, остальное только через докачку.
        let store = try Store.inMemory()
        let engine = SyncEngine(client: client, store: store, session: session)
        try await engine.syncOnce()
        var record = try #require(try await store.room(roomID))
        #expect(record.name?.hasPrefix("нютаг-тест") == true)
        #expect(record.topic == "тема из теста")
        #expect(record.membership == .join)
        let fromSync = try await store.eventCount(in: roomID)

        // Докачка назад до самого создания комнаты.
        var pages = 0
        while true {
            let step = try await engine.backfill(roomID: roomID, limit: 10)
            pages += 1
            if !step.hasMore || pages > 20 { break }
        }
        let events = try await store.events(in: roomID, limit: 500)
        print("live rooms: sync=\(fromSync) после докачки=\(events.count) страниц=\(pages)")
        #expect(events.first?.type == EventType.create, "история должна начинаться с m.room.create")
        let bodies = events.filter { $0.type == EventType.message }.compactMap { $0.content["body"]?.string }
        #expect(bodies.contains("сообщение 25"))
        #expect(Set(events.compactMap(\.eventID)).count == events.count, "без дублей")
        #expect(events.count > fromSync, "докачка должна добавить старые события")
        let firstMessage = try await client.event(roomID: roomID, eventID: sent[0])
        #expect(firstMessage.content["body"] == nil, "удалённое сообщение без тела")

        try await client.setReadMarkers(roomID: roomID, fullyRead: sent.last, read: sent.last)
        try await client.setTyping(roomID: roomID, userID: session.userID, typing: true)
        try await client.setTyping(roomID: roomID, userID: session.userID, typing: false)
        let members = try await client.members(roomID: roomID)
        #expect(members.contains { $0.stateKey == session.userID })

        try await client.setAccountData(userID: session.userID, type: "chat.nyutag.test", content: ["n": 1])
        let data = try await client.accountData(userID: session.userID, type: "chat.nyutag.test")
        #expect(data["n"]?.int == 1)

        try await engine.leave(roomID: roomID)
        try await engine.syncOnce()
        record = try #require(try await store.room(roomID))
        #expect(record.membership == .leave, "выход должен прийти в rooms.leave")
        try await client.forget(roomID: roomID)
        try await store.deleteRoom(roomID)
        #expect(try await store.room(roomID) == nil)
        #expect(try await store.eventCount(in: roomID) == 0)
    }

    private func media(client: MatrixClient) async throws {
        let payload = Data("нютаг медиа \(TransactionID.make())".utf8)
        let mxc = try await client.uploadMedia(payload, contentType: "text/plain", filename: "test.txt")
        #expect(mxc.server == "nyutag.chat")
        #expect(try await client.downloadMedia(mxc) == payload)
        let limit = try await client.mediaUploadLimit()
        print("live media: \(mxc) limit=\(limit.map(String.init) ?? "-")")

        let dir = FileManager.default.temporaryDirectory.appending(path: "nyutag-media-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try MediaCache(client: client, directory: dir)
        #expect(try await cache.data(mxc) == payload)
        #expect(try await cache.totalBytes() == payload.count)
    }

    private func nyutagInvites(client: MatrixClient) async throws {
        guard let api = LiveEnv.api else { return }
        let service = NyutagService(baseURL: api, accessToken: await client.accessToken)
        let invite = try await service.createInvite()
        #expect(invite.code.count >= 8)
        #expect((invite.expiresAt ?? .distantPast) > Date())
        #expect(try await service.invites().contains { $0.invite.code == invite.code })
        #expect(try await service.checkInvite(invite.code).valid)
        try await service.revokeInvite(invite.code)
        #expect(try await !service.invites().contains { $0.invite.code == invite.code })
        _ = try await service.hasPhone()
        #expect(try await service.lookup(phones: ["+70000000000"]).isEmpty)
    }

    @Test(.enabled(if: LiveEnv.api != nil)) func nyutagPublicEndpoints() async throws {
        let service = NyutagService(baseURL: LiveEnv.api!)
        let config = try await service.configuration()
        print("live nyutag: invite=\(config.requiresInvite) email=\(config.emailAvailable) phone=\(config.phoneAvailable)")
        let catalogue = try await service.catalogue()
        #expect(catalogue["paths"]?.array?.isEmpty == false)
        #expect(catalogue["doors"]?.array?.isEmpty == false, "двери-сайты для Нютага 2")
        _ = try await service.announcements()
        do {
            let check = try await service.checkInvite("НЕТТАКОГО")
            #expect(!check.valid)
        } catch {
            #expect(error.status != nil, "неверный код: ошибка сервера, не сети")
        }
    }

    @Test func wrongPasswordIsForbidden() async throws {
        let client = MatrixClient(homeserver: LiveEnv.homeserver!)
        do {
            _ = try await client.login(user: LiveEnv.user!, password: "неверный", deviceDisplayName: "тест")
            Issue.record("вход с неверным паролем прошёл")
        } catch {
            #expect(error.errcode == "M_FORBIDDEN")
            #expect(error.status == 403)
        }
    }
}
