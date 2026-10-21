// Собеседник для проверки звонка на iPhone: Мак входит в E2EE-учётку и звонит основной тестовой (или ждёт её
// звонка), вместо микрофона — тон 440 Гц. Сигналы идут через ядро как у приложения, кадры — через релей
// (SOCKS до ядра, см. LiveCallRelayTests).
//   NYUTAG_CALL_PEER=answer — ждать звонка с телефона и принять его;
//   NYUTAG_CALL_PEER=dial   — позвонить на телефон самому.
//   NYUTAG_CALL_SECONDS     — сколько говорить до отбоя (по умолчанию 20).
// В конце выход: устройство Мака удаляется.

import Foundation
@testable import NyutagCore
import Testing

@Suite(.enabled(if: ProcessInfo.processInfo.environment["NYUTAG_CALL_PEER"] != nil && LiveE2EEEnv.available
                    && ProcessInfo.processInfo.environment["NYUTAG_TEST_SOCKS"] != nil, "нет NYUTAG_CALL_PEER"))
struct LiveCallPeerTests {
    @Test func peer() async throws {
        let env = ProcessInfo.processInfo.environment
        let dial = env["NYUTAG_CALL_PEER"] == "dial"
        let talk = env["NYUTAG_CALL_SECONDS"].flatMap(Double.init) ?? 20
        let client = MatrixClient(homeserver: LiveEnv.homeserver!)
        let session: Session
        do {
            session = try await client.login(user: LiveE2EEEnv.user!, password: LiveE2EEEnv.password!,
                                             deviceDisplayName: "Нютаг тест звонка (Мак)")
        } catch let error as MatrixError where error.retryAfter != nil {
            // Сервер ограничивает частые входы: ждём, сколько просит, и пробуем ещё раз.
            print("call peer: вход отложен на \(error.retryAfter!)")
            try await Task.sleep(for: error.retryAfter! + .seconds(2))
            session = try await client.login(user: LiveE2EEEnv.user!, password: LiveE2EEEnv.password!,
                                             deviceDisplayName: "Нютаг тест звонка (Мак)")
        }
        do {
            try await run(client, session, dial: dial, talk: talk)
        } catch {
            print("call peer: ошибка \(error)")
            try? await client.logout()
            throw error
        }
        try await client.logout()
    }

    private func run(_ client: MatrixClient, _ session: Session, dial: Bool, talk: Double) async throws {
        let store = try Store.inMemory()
        let machine = try await CryptoMachine(client: client, store: store, session: session)
        try await machine.publishKeys(serverCount: nil)
        let engine = SyncEngine(client: client, store: store, session: session)
        await engine.addObserver(machine)
        _ = try await engine.syncOnce()

        let phone = "@\(LiveEnv.user!):nyutag.chat"
        let roomID = try await sharedRoom(with: phone, store: store, client: client, me: session.userID)
        let phoneDevices = try await machine.devices(for: [phone])
        print("call peer: устройства телефона: \(phoneDevices.map(\.deviceID).joined(separator: ", "))")
        print("call peer: комната с телефоном \(roomID.prefix(8))…, шифр \(try await store.room(roomID)?.isEncrypted == true)")

        let port = UInt16(ProcessInfo.processInfo.environment["NYUTAG_TEST_SOCKS"]!)!
        let route = Route.socks5(try #require(SocksProxy(port: port, user: "probe", password: "probe")))
        let core = MatrixClient(homeserver: URL(string: "https://core.nyutag.chat:6167")!,
                                accessToken: session.accessToken, delegate: CertificateTrust.nyutagCore(), route: route)
        let callEnv = CallEnvironment(
            me: session.userID, deviceID: session.deviceID,
            post: { signal, room in
                if signal.wantsRoomEncryption, try await store.room(room)?.isEncrypted == true {
                    _ = try await machine.sendEncrypted(roomID: room, type: signal.eventType, content: signal.content)
                } else {
                    _ = try await client.send(roomID: room, type: signal.eventType, content: signal.content)
                }
            },
            openTransport: { slot in await RelayLink.open(client: core, slot: slot) },
            makeVoice: { ToneVoice() })
        let center = CallCenter(callEnv)

        var call: CallSession?
        if dial {
            call = await center.dial(roomID: roomID, peer: phone)
            print("call peer: звоню на телефон")
        } else {
            print("call peer: жду звонка с телефона")
        }
        var incoming = center.incoming.makeAsyncIterator()
        let deadline = Date().addingTimeInterval(180)
        var liveSince: Date?
        var lastPhase: CallPhase?
        while Date() < deadline {
            let update = try await engine.syncOnce(timeout: .seconds(1))
            let fresh = Int(Date().timeIntervalSince1970 * 1000) - 120_000
            for (room, joined) in update.response.joined {
                for event in joined.timeline.events where (event.originServerTS ?? 0) > fresh {
                    var clear = event
                    if event.type == EventType.encrypted {
                        guard let opened = try? await machine.decrypt(event, roomID: room).event else {
                            print("call peer: не расшифровалось событие от \(event.sender ?? "?")")
                            continue
                        }
                        clear = opened
                    }
                    if let message = CallMessage(clear, roomID: room) {
                        print("call peer: сигнал \(clear.type) от \(message.sender == session.userID ? "себя" : "телефона")")
                        await center.absorb(message)
                    }
                }
            }
            if call == nil, await center.active() != nil, let session = await incoming.next() {
                call = session
                print("call peer: входящий, принимаю")
                await session.accept()
            }
            guard let call else { continue }
            let phase = await call.phase
            if phase != lastPhase {
                print("call peer: фаза \(phase)")
                lastPhase = phase
            }
            if case .live(let since) = phase {
                liveSince = since
                if let stats = await call.stats {
                    print("call peer: ушло \(stats.sent), пришло \(stats.received), сыграно \(stats.played), потеряно \(stats.lost), слышно \(String(format: "%.3f", stats.outputLevel))")
                }
                if Date().timeIntervalSince(since) > talk { await call.hangUp() }
            }
            if phase.isEnded {
                #expect(liveSince != nil, "разговор не начался: \(phase)")
                return
            }
        }
        Issue.record("звонок не закончился за 3 минуты")
        await call?.hangUp()
    }

    /// Личный чат с телефоном; если нет — создаём (обе учётки тестовые).
    private func sharedRoom(with phone: String, store: Store, client: MatrixClient, me: String) async throws -> String {
        for room in try await store.rooms(membership: .join) {
            let members = try await store.state(room.id, type: EventType.member)
                .filter { ["join", "invite"].contains($0.content["membership"]?.string ?? "") }
                .map(\.stateKey)
            if Set(members) == [me, phone] { return room.id }
        }
        print("call peer: общего чата нет, создаю личный")
        return try await client.createDirectRoom(userID: me, with: phone)
    }
}
