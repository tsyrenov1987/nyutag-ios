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

    /// Две учётки переписываются в новой зашифрованной комнате: ключ комнаты уходит по Olm через сервер,
    /// сообщения в обе стороны расшифровываются, ключ своей сессии попадает в бэкап. В конце комната забыта, выход.
    @Test(.enabled(if: LiveEnv.available, "нет NYUTAG_TEST_USER")) func twoAccountsTalkEncrypted() async throws {
        let hs = LiveEnv.homeserver!
        let aliceClient = MatrixClient(homeserver: hs)
        let bobClient = MatrixClient(homeserver: hs)
        let aliceSession = try await aliceClient.login(user: LiveEnv.user!, password: LiveEnv.password!,
                                                       deviceDisplayName: "Нютаг тест отправки (Мак)")
        let bobSession: Session
        do {
            bobSession = try await bobClient.login(user: LiveE2EEEnv.user!, password: LiveE2EEEnv.password!,
                                                   deviceDisplayName: "Нютаг тест отправки (Мак)")
        } catch {
            try? await aliceClient.logout()
            throw error
        }
        do {
            try await talk(alice: (aliceClient, aliceSession), bob: (bobClient, bobSession))
        } catch {
            print("live e2ee: ошибка \(error)")
            try? await aliceClient.logout()
            try? await bobClient.logout()
            throw error
        }
        try await aliceClient.logout()
        try await bobClient.logout()
    }

    private func cleanup(_ roomID: String, _ clients: MatrixClient...) async {
        for client in clients {
            try? await client.leave(roomID: roomID)
            try? await client.forget(roomID: roomID)
        }
    }

    /// Ждёт, пока событие расшифруется: ключ приходит to-device в одном из следующих /sync.
    private func readLatest(_ client: MatrixClient, _ machine: CryptoMachine, _ engine: SyncEngine,
                            roomID: String, from sender: String) async throws -> [String] {
        for _ in 0..<8 {
            _ = try await engine.syncOnce(timeout: .seconds(2))
            let page = try await client.messages(roomID: roomID, from: nil, limit: 50)
            var bodies: [String] = []
            var pending = false
            for event in page.events.reversed() where event.type == EventType.encrypted && event.sender == sender {
                do {
                    let decrypted = try await machine.decrypt(event, roomID: roomID)
                    bodies.append(decrypted.event.content["body"]?.string ?? "")
                } catch E2EEError.missingSession {
                    pending = true
                }
            }
            if !pending, !bodies.isEmpty { return bodies }
        }
        return []
    }

    private func talk(alice: (MatrixClient, Session), bob: (MatrixClient, Session)) async throws {
        let aliceMachine = try await CryptoMachine(client: alice.0, store: try Store.inMemory(), session: alice.1)
        let aliceEngine = SyncEngine(client: alice.0, store: await aliceMachine.store, session: alice.1)
        await aliceEngine.addObserver(aliceMachine)
        let bobStore = try Store.inMemory()
        let bobMachine = try await CryptoMachine(client: bob.0, store: bobStore, session: bob.1)
        let bobEngine = SyncEngine(client: bob.0, store: bobStore, session: bob.1)
        await bobEngine.addObserver(bobMachine)
        _ = try await aliceEngine.syncOnce()
        _ = try await bobEngine.syncOnce()

        let roomID = try await alice.0.createRoom(.init(name: "Нютаг тест шифрования", invite: [bob.1.userID]))
        print("live e2ee: комната создана")
        do {
            try await converse(roomID: roomID, alice: (alice.0, alice.1, aliceMachine, aliceEngine),
                               bob: (bob.0, bob.1, bobMachine, bobEngine))
        } catch {
            await cleanup(roomID, alice.0, bob.0)
            throw error
        }
        await cleanup(roomID, alice.0, bob.0)
    }

    private func converse(roomID: String, alice: (MatrixClient, Session, CryptoMachine, SyncEngine),
                          bob: (MatrixClient, Session, CryptoMachine, SyncEngine)) async throws {
        let (aliceMachine, aliceEngine, bobMachine, bobEngine) = (alice.2, alice.3, bob.2, bob.3)
        _ = try await bob.0.join(roomID)
        _ = try await aliceEngine.syncOnce()
        _ = try await bobEngine.syncOnce()

        let stamp = ISO8601DateFormatter().string(from: Date())
        try await aliceMachine.sendEncrypted(roomID: roomID, type: EventType.message,
                                             content: ["msgtype": "m.text", "body": .string("сайн байна \(stamp)")])
        let atBob = try await readLatest(bob.0, bobMachine, bobEngine, roomID: roomID, from: alice.1.userID)
        print("live e2ee: Боб прочитал \(atBob.count)")
        #expect(atBob == ["сайн байна \(stamp)"])

        try await bobMachine.sendEncrypted(roomID: roomID, type: EventType.message,
                                           content: ["msgtype": "m.text", "body": .string("сайн \(stamp)")])
        let atAlice = try await readLatest(alice.0, aliceMachine, aliceEngine, roomID: roomID, from: bob.1.userID)
        print("live e2ee: Алиса прочитала \(atAlice.count)")
        #expect(atAlice == ["сайн \(stamp)"])

        // Бэкап Боба: ключ поднят по коду, свежие ключи комнаты (свой и полученный) выгружены.
        try await bobMachine.restoreBackup(recoveryKey: LiveE2EEEnv.recovery!)
        let uploaded = try await bobMachine.uploadRoomKeysToBackup()
        let version = try #require(try await bob.0.backupVersion()).version
        let inBackup = try await bob.0.backupKeys(version: version)[roomID]?.count ?? 0
        print("live e2ee: в бэкап выгружено \(uploaded), сессий комнаты в бэкапе \(inBackup)")
        #expect(inBackup == 2)
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
