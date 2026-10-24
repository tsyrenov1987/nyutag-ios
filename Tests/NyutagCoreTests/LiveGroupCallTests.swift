// Групповой звонок вживую: Мак входит двумя тестовыми учётками (третьей и четвёртой), третий участник —
// симулятор или телефон с E2EE-учёткой. Основную учётку (телефон владельца) не трогаем: ей не звонит.
// Комната «Проверка групповых звонков» — шифрованная, недостающих участников приглашаем; E2EE-учётка входит
// в неё с Мака и выходит. Сигналы через ядро, кадры через релей (дверь к ядру).
//   NYUTAG_CALL_GROUP=1         — включить;
//   NYUTAG_TEST_THIRD_USER/_PASSWORD, NYUTAG_TEST_FOURTH_USER/_PASSWORD — учётки Мака;
//   NYUTAG_CALL_SECONDS         — сколько говорить (по умолчанию 20).
// Первая учётка звонит, вторая принимает, телефон принимает сам (NYUTAG_UI_CALL_ANSWER) или руками.
// В конце выход обеих: устройства Мака удаляются.

import Foundation
@testable import NyutagCore
import Testing

@Suite(.enabled(if: ProcessInfo.processInfo.environment["NYUTAG_CALL_GROUP"] != nil && LiveE2EEEnv.available
                    && LiveEnv.homeserver != nil && ProcessInfo.processInfo.environment["NYUTAG_TEST_THIRD_USER"] != nil
                    && ProcessInfo.processInfo.environment["NYUTAG_TEST_FOURTH_USER"] != nil
                    && LiveEnv.doorAvailable, "нет NYUTAG_CALL_GROUP"))
struct LiveGroupCallTests {
    static let env = ProcessInfo.processInfo.environment

    @Test func groupCall() async throws {
        let talk = Self.env["NYUTAG_CALL_SECONDS"].flatMap(Double.init) ?? 20
        let first = try await Party.login(Self.env["NYUTAG_TEST_THIRD_USER"]!, Self.env["NYUTAG_TEST_THIRD_PASSWORD"]!)
        let second = try await Party.login(Self.env["NYUTAG_TEST_FOURTH_USER"]!, Self.env["NYUTAG_TEST_FOURTH_PASSWORD"]!)
        do {
            try await run(first, second, talk: talk)
        } catch {
            print("group call: ошибка \(error)")
            try? await first.client.logout()
            try? await second.client.logout()
            throw error
        }
        try await first.client.logout()
        try await second.client.logout()
    }

    private func run(_ first: Party, _ second: Party, talk: Double) async throws {
        let phone = "@\(LiveE2EEEnv.user!):nyutag.chat"
        let roomID = try await groupRoom(first, second, phone: phone)
        try await first.start()
        try await second.start()
        print("group call: комната \(roomID.prefix(8))…, шифр \(try await first.store.room(roomID)?.isEncrypted == true)")

        let call = try #require(await first.center.dialGroup(roomID: roomID))
        print("group call: первая учётка звонит")
        var incoming = second.center.incoming.makeAsyncIterator()
        var answered: CallSession?
        let deadline = Date().addingTimeInterval(180)
        var liveSince: Date?
        var report = Date()
        while Date() < deadline {
            try await first.pump()
            try await second.pump()
            if answered == nil, await second.center.active() != nil, let session = await incoming.next() {
                answered = session
                print("group call: вторая учётка приняла")
                await session.accept()
            }
            let phase = await call.phase
            if case .live(let since) = phase {
                liveSince = liveSince ?? since
                if Date().timeIntervalSince(report) > 3 {
                    report = Date()
                    for (name, session) in [("первая", call), ("вторая", answered)] {
                        guard let session else { continue }
                        let others = await session.others.map { $0.user == phone ? "телефон" : "учётка" }
                        if let stats = await session.stats {
                            print("group call: \(name): с ней \(others), ушло \(stats.sent), пришло \(stats.received), сыграно \(stats.played), потеряно \(stats.lost), слышно \(String(format: "%.3f", stats.outputLevel))")
                        }
                    }
                }
                if Date().timeIntervalSince(since) > talk {
                    let withPhone = await call.others.contains { $0.user == phone }
                    #expect(withPhone, "телефон не вошёл в звонок")
                    if let stats = await call.stats, stats.sent > 0 {
                        // Слышит двоих: кадров приходит почти вдвое больше, чем уходит.
                        print("group call: первая принимает \(String(format: "%.2f", Double(stats.received) / Double(stats.sent))) кадра на свой")
                    }
                    await call.hangUp()
                    await answered?.hangUp()
                }
            }
            if phase.isEnded {
                print("group call: конец \(phase)")
                #expect(liveSince != nil, "разговор не начался: \(phase)")
                // Последние leave до телефона.
                try await first.pump()
                return
            }
        }
        Issue.record("звонок не закончился за 3 минуты")
        await call.hangUp()
    }

    /// Шифрованная группа «Проверка групповых звонков»: нет — создаём, недостающих приглашаем и вводим.
    private func groupRoom(_ first: Party, _ second: Party, phone: String) async throws -> String {
        _ = try await first.engine.syncOnce()
        let name = "Проверка групповых звонков"
        var roomID: String?
        for room in try await first.store.rooms(membership: .join) where room.isEncrypted && room.name == name {
            roomID = room.id
        }
        if roomID == nil {
            print("group call: группы нет, создаю")
            roomID = try await first.client.createRoom(.init(name: name, invite: [second.session.userID, phone]))
        }
        let room = roomID!
        let joined = Set(try await first.store.state(room, type: EventType.member)
            .filter { $0.content["membership"]?.string == "join" }
            .map(\.stateKey))
        if !joined.contains(second.session.userID) {
            try? await first.client.invite(roomID: room, userID: second.session.userID)
            try await second.client.join(room)
        }
        if !joined.contains(phone) {
            try? await first.client.invite(roomID: room, userID: phone)
            // E2EE-учётка входит с Мака и сразу выходит: её телефон увидит комнату уже участником.
            let client = MatrixClient(homeserver: LiveEnv.homeserver!)
            _ = try await client.login(user: LiveE2EEEnv.user!, password: LiveE2EEEnv.password!,
                                       deviceDisplayName: "Нютаг тест группы (Мак)")
            try await client.join(room)
            try await client.logout()
        }
        return room
    }
}

/// Одна учётка на Маке: шифр, синхронизация и диспетчер звонков.
private final class Party: @unchecked Sendable {
    let client: MatrixClient
    let session: Session
    let store: Store
    let machine: CryptoMachine
    let engine: SyncEngine
    private(set) var center: CallCenter!

    private init(client: MatrixClient, session: Session) async throws {
        self.client = client
        self.session = session
        store = try Store.inMemory()
        machine = try await CryptoMachine(client: client, store: store, session: session)
        engine = SyncEngine(client: client, store: store, session: session)
    }

    static func login(_ user: String, _ password: String) async throws -> Party {
        let client = MatrixClient(homeserver: LiveEnv.homeserver!)
        let session: Session
        do {
            session = try await client.login(user: user, password: password, deviceDisplayName: "Нютаг тест группы (Мак)")
        } catch let error as MatrixError where error.retryAfter != nil {
            print("group call: вход отложен на \(error.retryAfter!)")
            try await Task.sleep(for: error.retryAfter! + .seconds(2))
            session = try await client.login(user: user, password: password, deviceDisplayName: "Нютаг тест группы (Мак)")
        }
        return try await Party(client: client, session: session)
    }

    func start() async throws {
        try await machine.publishKeys(serverCount: nil)
        await engine.addObserver(machine)
        _ = try await engine.syncOnce()
        let core = LiveEnv.doorClient(accessToken: session.accessToken)
        let client = client, machine = machine
        center = CallCenter(CallEnvironment(
            me: session.userID, deviceID: session.deviceID,
            // Как в приложении: всё, кроме будильника, шифром комнаты, даже открытой.
            post: { signal, room in
                if signal.wantsRoomEncryption {
                    _ = try await machine.sendEncrypted(roomID: room, type: signal.eventType, content: signal.content)
                } else {
                    _ = try await client.send(roomID: room, type: signal.eventType, content: signal.content)
                }
            },
            openTransport: { slot in await RelayLink.open(client: core, slot: slot) },
            makeVoice: { ToneVoice() }))
    }

    /// Одна короткая синхронизация: сигналы звонка — в диспетчер.
    func pump() async throws {
        let update = try await engine.syncOnce(timeout: .milliseconds(500))
        let fresh = Int(Date().timeIntervalSince1970 * 1000) - 120_000
        for (room, joined) in update.response.joined {
            for event in joined.timeline.events where (event.originServerTS ?? 0) > fresh {
                var clear = event
                if event.type == EventType.encrypted {
                    guard let opened = try? await machine.decrypt(event, roomID: room).event else { continue }
                    clear = opened
                }
                if let message = CallMessage(clear, roomID: room) { await center.absorb(message) }
            }
        }
    }
}
