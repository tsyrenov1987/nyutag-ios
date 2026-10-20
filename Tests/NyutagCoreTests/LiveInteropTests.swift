// Живая сверка на ядре (Tuwunel) того, что до сих пор проверялось только на поддельном сервере: проверка по эмодзи
// в комнате, зашифрованные вложения (EncryptedFile v2), поля профиля MSC4133 и стук в комнату (knock). Плюс
// настоящие вложения из истории test14, зашифрованные клиентами форка (Element X / Element Android).
// Один вход на учётку (Tuwunel отвечает 429 на частые входы). В конце комнаты забыты, поле профиля
// возвращено, обе сессии вышли. Переменные: NYUTAG_TEST_HS, NYUTAG_TEST_USER/PASSWORD, NYUTAG_TEST_E2EE_*.

import Foundation
@testable import NyutagCore
import NyutagCrypto
import Testing

@Suite(.enabled(if: LiveEnv.available && LiveE2EEEnv.available, "нет NYUTAG_TEST_*")) struct LiveInteropTests {
    struct Party {
        let client: MatrixClient
        let session: Session
        let machine: CryptoMachine
        let engine: SyncEngine
    }

    @Test func roomVerificationAttachmentsProfileKnock() async throws {
        let hs = LiveEnv.homeserver!
        var logged: [MatrixClient] = []
        var rooms: [String] = []
        var parties: [Party] = []
        do {
            for (user, password) in [(LiveEnv.user!, LiveEnv.password!), (LiveE2EEEnv.user!, LiveE2EEEnv.password!)] {
                let client = MatrixClient(homeserver: hs)
                let session = try await client.login(user: user, password: password,
                                                     deviceDisplayName: "Нютаг тест сверки (Мак)")
                logged.append(client)
                let store = try Store.inMemory()
                let machine = try await CryptoMachine(client: client, store: store, session: session)
                try await machine.publishKeys(serverCount: nil)
                let engine = SyncEngine(client: client, store: store, session: session)
                await engine.addObserver(machine)
                _ = try await engine.syncOnce()
                parties.append(Party(client: client, session: session, machine: machine, engine: engine))
            }
            let (alice, bob) = (parties[0], parties[1])
            try await bob.machine.importCrossSigning(recoveryKey: LiveE2EEEnv.recovery!)

            let roomID = try await alice.client.createRoom(.init(name: "Нютаг тест сверки", invite: [bob.session.userID]))
            rooms.append(roomID)
            _ = try await bob.client.join(roomID)
            try await deliver(parties)

            try await attachment(roomID: roomID, alice: alice, bob: bob, parties: parties)
            try await verifyInRoom(roomID: roomID, alice: alice, bob: bob, parties: parties)
            try await profileFields(alice: alice, bob: bob)
            rooms.append(try await knock(alice: alice, bob: bob, parties: parties))
            try await forkAttachments(bob)
        } catch {
            print("live interop: ошибка \(error)")
            await finish(logged, rooms)
            throw error
        }
        await finish(logged, rooms)
    }

    private func finish(_ clients: [MatrixClient], _ rooms: [String]) async {
        for client in clients {
            for room in rooms {
                try? await client.leave(roomID: room)
                try? await client.forget(roomID: room)
            }
            try? await client.logout()
        }
    }

    private func deliver(_ parties: [Party], rounds: Int = 2) async throws {
        for _ in 0..<rounds { for party in parties { _ = try await party.engine.syncOnce(timeout: .seconds(1)) } }
    }

    /// Последнее зашифрованное событие отправителя, расшифрованное (ключ приходит to-device в одном из /sync).
    private func latestDecrypted(_ party: Party, roomID: String, from sender: String) async throws -> Event? {
        for _ in 0..<8 {
            _ = try await party.engine.syncOnce(timeout: .seconds(2))
            let page = try await party.client.messages(roomID: roomID, from: nil, limit: 20)
            guard let event = page.events.first(where: { $0.type == EventType.encrypted && $0.sender == sender }) else {
                continue
            }
            if let decrypted = try? await party.machine.decrypt(event, roomID: roomID) { return decrypted.event }
        }
        return nil
    }

    // MARK: Вложение

    private func attachment(roomID: String, alice: Party, bob: Party, parties: [Party]) async throws {
        let original = Data((0..<150_000).map { _ in UInt8.random(in: 0...255) })
        let file = try await alice.client.uploadEncrypted(original, contentType: "application/octet-stream")
        let content = try file.content(msgtype: "m.file", body: "проба.bin",
                                       info: ["mimetype": "application/octet-stream", "size": .int(original.count)])
        _ = try await alice.machine.sendEncrypted(roomID: roomID, type: EventType.message, content: content)
        let event = try #require(try await latestDecrypted(bob, roomID: roomID, from: alice.session.userID))
        let received = try JSONDecoder().decode(EncryptedFile.self, from: JSONEncoder().encode(try #require(event.content["file"])))
        let data = try await bob.client.downloadDecrypted(received)
        print("live interop: вложение \(data.count) Б, совпало \(data == original), v=\(received.v)")
        #expect(data == original)
        #expect(event.content["url"] == nil)

        // Подмена шифртекста на сервере не проходит проверку хеша.
        var tampered = received
        tampered.hashes["sha256"] = file.hashes["sha256"].map { String($0.reversed()) }
        await #expect(throws: (any Error).self) { _ = try await bob.client.downloadDecrypted(tampered) }
    }

    // MARK: Проверка в комнате

    private func verifyInRoom(roomID: String, alice: Party, bob: Party, parties: [Party]) async throws {
        let id = try await alice.machine.requestVerification(userID: bob.session.userID, inRoom: roomID)
        try await deliver(parties)
        #expect(await bob.machine.verification(id)?.state == .requested)
        try await bob.machine.acceptVerification(id)
        try await deliver(parties)
        try await alice.machine.startSas(id)
        try await deliver(parties)
        let (a, b) = (await alice.machine.verification(id), await bob.machine.verification(id))
        let emoji = (a?.emoji ?? []).map { SasEmoji.table[$0].emoji }.joined()
        print("live interop: проверка в комнате, эмодзи \(emoji), совпали \(a?.emoji != nil && a?.emoji == b?.emoji)")
        #expect(a?.state == .comparing && b?.state == .comparing)
        #expect(a?.emoji != nil && a?.emoji == b?.emoji)
        try await alice.machine.confirmSas(id)
        try await bob.machine.confirmSas(id)
        try await deliver(parties, rounds: 3)
        let (atAlice, atBob) = (await alice.machine.verification(id)?.state, await bob.machine.verification(id)?.state)
        print("live interop: проверка в комнате \(String(describing: atAlice)) / \(String(describing: atBob))")
        #expect(atAlice == .done && atBob == .done)
    }

    // MARK: Профиль

    private func profileFields(alice: Party, bob: Party) async throws {
        let api = try await alice.client.profileFieldsAPI()
        print("live interop: поля профиля \(api)")
        guard api != .disabled else { return }
        let me = alice.session.userID
        let before = try await alice.client.profile(userID: me)[.about]
        let stamp = "сверка \(Int(Date().timeIntervalSince1970))"
        try await alice.client.applyProfileEdits(userID: me, [.about: stamp], api: api)
        let seen = try await bob.client.profile(userID: me)
        try await alice.client.applyProfileEdits(userID: me, [.about: before], api: api)
        let after = try await bob.client.profile(userID: me)[.about]
        let known = Set(seen.fields.keys).intersection(NyutagProfileKey.allCases.map(\.rawValue)).sorted()
        print("live interop: поле видно другому \(seen[.about] == stamp), возвращено \(after == before), поля \(known)")
        #expect(seen[.about] == stamp)
        #expect(after == before)
    }

    // MARK: Стук

    private func knock(alice: Party, bob: Party, parties: [Party]) async throws -> String {
        let roomID = try await alice.client.createRoom(.init(name: "Нютаг тест стука", preset: "private_chat",
                                                            encrypted: false))
        _ = try await alice.client.setState(roomID: roomID, type: EventType.joinRules, content: ["join_rule": "knock"])
        let knocked = try await bob.client.knock(roomID, reason: "сверка")
        #expect(knocked == roomID)
        let members = try await alice.client.members(roomID: roomID)
        let knock = members.first { $0.stateKey == bob.session.userID }
        print("live interop: стук виден \(knock?.content["membership"]?.string ?? "-"), причина \(knock?.content["reason"]?.string ?? "-")")
        #expect(knock?.content["membership"] == "knock")
        try await alice.client.invite(roomID: roomID, userID: bob.session.userID)
        _ = try await bob.client.join(roomID)
        let joined = try await alice.client.members(roomID: roomID).first { $0.stateKey == bob.session.userID }
        #expect(joined?.content["membership"] == "join")
        return roomID
    }

    // MARK: Вложения форка

    /// Вложения, которые зашифровали клиенты форка: ключи комнат — из бэкапа, файлы — с сервера.
    private func forkAttachments(_ bob: Party) async throws {
        _ = try await bob.machine.restoreBackup(recoveryKey: LiveE2EEEnv.recovery!)
        let version = try #require(try await bob.client.backupVersion()).version
        var tried = 0, ok = 0, failed: [String] = []
        rooms: for roomID in try await bob.client.backupKeys(version: version).keys.sorted() {
            guard let page = try? await bob.client.messages(roomID: roomID, from: nil, limit: 100) else { continue }
            for event in page.events where event.type == EventType.encrypted && event.sender != bob.session.userID {
                guard let decrypted = try? await bob.machine.decrypt(event, roomID: roomID).event,
                      let fileJSON = decrypted.content["file"] else { continue }
                tried += 1
                do {
                    let file = try JSONDecoder().decode(EncryptedFile.self, from: JSONEncoder().encode(fileJSON))
                    let data = try await bob.client.downloadDecrypted(file)
                    ok += 1
                    print("  вложение форка \(decrypted.content["msgtype"]?.string ?? "-") \(data.count) Б")
                } catch {
                    failed.append("\(event.eventID ?? "-"): \(error)")
                }
                if tried >= 5 { break rooms }
            }
        }
        print("live interop: вложений форка \(tried), расшифровано \(ok)")
        for line in failed { print("  ✗ \(line)") }
        #expect(failed.isEmpty)
    }
}
