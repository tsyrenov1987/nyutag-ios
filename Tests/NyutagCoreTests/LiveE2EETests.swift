// Живая приёмка шифрования: новое устройство учётки с бэкапом ключей (его собрал Android-клиент на vodozemac)
// поднимает ключи по recovery-коду и расшифровывает настоящие сообщения комнат. Публикует свои ключи устройства
// и проверяет, что сервер отдаёт их с верной подписью. В конце выход: устройство удаляется.
// Переменные: NYUTAG_TEST_HS, NYUTAG_TEST_E2EE_USER, NYUTAG_TEST_E2EE_PASSWORD, NYUTAG_TEST_E2EE_RECOVERY.

import Foundation
@testable import NyutagCore
import NyutagCrypto
import Testing

enum LiveE2EEEnv {
    static let env = ProcessInfo.processInfo.environment
    static let user = env["NYUTAG_TEST_E2EE_USER"]
    static let password = env["NYUTAG_TEST_E2EE_PASSWORD"]
    static let recovery = env["NYUTAG_TEST_E2EE_RECOVERY"]
    static var available: Bool { LiveEnv.homeserver != nil && user != nil && password != nil && recovery != nil }
}

@Suite(.enabled(if: LiveE2EEEnv.available, "нет NYUTAG_TEST_E2EE_*")) struct LiveE2EETests {
    @Test func restoreBackupAndDecryptRealRooms() async throws {
        let client = MatrixClient(homeserver: LiveEnv.homeserver!)
        let session = try await client.login(user: LiveE2EEEnv.user!, password: LiveE2EEEnv.password!,
                                             deviceDisplayName: "Нютаг тест шифрования (Мак)")
        do {
            try await run(client: client, session: session)
        } catch {
            try? await client.logout()
            throw error
        }
        try await client.logout()
    }

    private func run(client: MatrixClient, session: Session) async throws {
        let store = try Store.inMemory()
        let machine = try await CryptoMachine(client: client, store: store, session: session)
        let engine = SyncEngine(client: client, store: store, session: session)
        await engine.addObserver(machine)
        try await engine.syncOnce()

        // Неверный код отвергается до похода за ключами.
        await #expect(throws: E2EEError.wrongRecoveryKey) {
            try await machine.restoreBackup(recoveryKey: RecoveryKey.encode(Random.bytes(32)))
        }
        let restored = try await machine.restoreBackup(recoveryKey: LiveE2EEEnv.recovery!)
        print("live e2ee: бэкап \(restored.total) сессий, поднято \(restored.imported)")
        #expect(restored.total > 0)
        #expect(restored.imported > 0)

        // Ключи устройства на сервере и их подпись.
        let keys = try await client.queryKeys(userIDs: [session.userID])
        let device = try #require(keys["device_keys", session.userID, session.deviceID])
        #expect(device["keys", "ed25519:\(session.deviceID)"]?.string == machine.ed25519Key)
        #expect(CryptoMachine.verifySignature(device, userID: session.userID, keyID: session.deviceID,
                                              publicKey: machine.ed25519Key))
        let otkCount = try await client.uploadKeys()["signed_curve25519"] ?? 0
        print("live e2ee: ключи устройства на сервере, одноразовых \(otkCount)")
        #expect(otkCount >= 50)

        // Расшифровка: комнаты, ключи которых лежат в бэкапе, плюс зашифрованные комнаты из /sync.
        // Историю берём через /messages: так читаются и комнаты, из которых учётка уже вышла.
        let version = try #require(try await client.backupVersion()).version
        var roomIDs = Set(try await client.backupKeys(version: version).keys)
        for room in try await store.rooms(membership: .join) where room.isEncrypted { roomIDs.insert(room.id) }
        var ok = 0, missing = 0, total = 0, failed: [String] = []
        var bodies = 0
        for roomID in roomIDs.sorted() {
            var from: String?
            var seen = 0
            for _ in 0..<5 {
                let page: MessagesPage
                do {
                    page = try await client.messages(roomID: roomID, from: from, limit: 100)
                } catch {
                    print("  room \(roomID): /messages \(error.errcode ?? "\(error)")")
                    break
                }
                for event in page.events where event.type == EventType.encrypted {
                    seen += 1
                    do {
                        let decrypted = try await machine.decrypt(event, roomID: roomID)
                        ok += 1
                        if decrypted.event.content["body"]?.string != nil { bodies += 1 }
                    } catch E2EEError.missingSession {
                        missing += 1
                    } catch {
                        failed.append("\(roomID) \(event.eventID ?? "-"): \(error)")
                    }
                }
                guard let end = page.end else { break }
                from = end
            }
            print("  room \(roomID): зашифрованных \(seen)")
            total += seen
        }
        print("live e2ee: расшифровано \(ok) (с текстом \(bodies)), нет ключа \(missing), ошибок \(failed.count)")
        for line in failed.prefix(5) { print("  ✗ \(line)") }
        // Доступных зашифрованных событий может не быть (учётка вышла из комнат); тогда проверка — в InteropTests.
        if total > 0 { #expect(ok > 0) }
        #expect(failed.isEmpty)
    }
}
