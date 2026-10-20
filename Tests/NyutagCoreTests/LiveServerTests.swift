// Живой тест против ядра nyutag.chat. Запускается только при заданных переменных окружения
// (`tools/test-env.sh`): NYUTAG_TEST_HS (адрес Tuwunel), NYUTAG_TEST_USER, NYUTAG_TEST_PASSWORD.

import Foundation
@testable import NyutagCore
import Testing

enum LiveEnv {
    static let homeserver = ProcessInfo.processInfo.environment["NYUTAG_TEST_HS"].flatMap(URL.init(string:))
    static let user = ProcessInfo.processInfo.environment["NYUTAG_TEST_USER"]
    static let password = ProcessInfo.processInfo.environment["NYUTAG_TEST_PASSWORD"]
    static var available: Bool { homeserver != nil && user != nil && password != nil }
}

@Suite(.enabled(if: LiveEnv.available, "нет NYUTAG_TEST_HS/USER/PASSWORD")) struct LiveServerTests {
    @Test func versionsLoginWhoAmISyncLogout() async throws {
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

        try await client.logout()
        await #expect(throws: MatrixError.self) { try await client.whoAmI() }
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
