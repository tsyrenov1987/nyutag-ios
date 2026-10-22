// Собеседник для проверки звонка на iPhone: Мак входит в E2EE-учётку и звонит основной тестовой (или ждёт её
// звонка), вместо микрофона — тон 440 Гц. Сигналы идут через ядро как у приложения, кадры — через релей
// (дверь к ядру, см. LiveCallRelayTests).
//   NYUTAG_CALL_PEER=answer — ждать звонка с телефона и принять его;
//   NYUTAG_CALL_PEER=dial   — позвонить на телефон самому;
//   NYUTAG_CALL_PEER=once   — без звонка: послать фото «один просмотр» и ждать, пока телефон его откроет.
//   NYUTAG_CALL_SECONDS     — сколько говорить до отбоя (по умолчанию 20).
//   NYUTAG_CALL_TEXT        — после звонка послать в чат текст (проверка пушей).
//   NYUTAG_CALL_VIDEO       — видеозвонок: вместо камеры полосы, кадры собеседника считаем.
//   NYUTAG_CALL_SWAP        — учётки наоборот: Мак входит основной, собеседник — E2EE-учётка (симулятор ночью,
//                             чтобы не звенел телефон владельца: своих событий сервер в пуш не шлёт).
// В конце выход: устройство Мака удаляется.

import Foundation
@testable import NyutagCore
import Testing

@Suite(.enabled(if: ProcessInfo.processInfo.environment["NYUTAG_CALL_PEER"] != nil && LiveE2EEEnv.available
                    && LiveEnv.doorAvailable, "нет NYUTAG_CALL_PEER или двери"))
struct LiveCallPeerTests {
    @Test func peer() async throws {
        let env = ProcessInfo.processInfo.environment
        let dial = env["NYUTAG_CALL_PEER"] == "dial"
        let talk = env["NYUTAG_CALL_SECONDS"].flatMap(Double.init) ?? 20
        let swap = env["NYUTAG_CALL_SWAP"] != nil
        let user = swap ? LiveEnv.user! : LiveE2EEEnv.user!, password = swap ? LiveEnv.password! : LiveE2EEEnv.password!
        let client = MatrixClient(homeserver: LiveEnv.homeserver!)
        let session: Session
        do {
            session = try await client.login(user: user, password: password,
                                             deviceDisplayName: "Нютаг тест звонка (Мак)")
        } catch let error as MatrixError where error.retryAfter != nil {
            // Сервер ограничивает частые входы: ждём, сколько просит, и пробуем ещё раз.
            print("call peer: вход отложен на \(error.retryAfter!)")
            try await Task.sleep(for: error.retryAfter! + .seconds(2))
            session = try await client.login(user: user, password: password,
                                             deviceDisplayName: "Нютаг тест звонка (Мак)")
        }
        do {
            try await run(client, session, dial: dial, talk: talk, phone: "@\(swap ? LiveE2EEEnv.user! : LiveEnv.user!):nyutag.chat")
        } catch {
            print("call peer: ошибка \(error)")
            try? await client.logout()
            throw error
        }
        try await client.logout()
    }

    private func run(_ client: MatrixClient, _ session: Session, dial: Bool, talk: Double, phone: String) async throws {
        let video = ProcessInfo.processInfo.environment["NYUTAG_CALL_VIDEO"] != nil
        let store = try Store.inMemory()
        let machine = try await CryptoMachine(client: client, store: store, session: session)
        try await machine.publishKeys(serverCount: nil)
        let engine = SyncEngine(client: client, store: store, session: session)
        await engine.addObserver(machine)
        _ = try await engine.syncOnce()

        let roomID = try await sharedRoom(with: phone, store: store, client: client, me: session.userID)
        let phoneDevices = try await machine.devices(for: [phone])
        print("call peer: устройства телефона: \(phoneDevices.map(\.deviceID).joined(separator: ", "))")
        print("call peer: комната с телефоном \(roomID), шифр \(try await store.room(roomID)?.isEncrypted == true)")
        if ProcessInfo.processInfo.environment["NYUTAG_CALL_PEER"] == "once" {
            try await sendViewOnce(client, machine, roomID: roomID)
            return
        }

        let core = LiveEnv.doorClient(accessToken: session.accessToken)
        var callEnv = CallEnvironment(
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
        callEnv.notify = { signal, user in
            let sent = (try? await client.sendToDevice(type: signal.eventType, messages: [user: ["*": signal.content]])) != nil
            print("call peer: \(signal.eventType) устройствам \(sent ? "ушёл" : "не ушёл")")
        }
        if video { callEnv.makeCamera = { PatternCamera() } }
        // NYUTAG_CALL_ANSWER_AFTER — сколько секунд звенеть, прежде чем принять: послушать гудки у звонящего.
        let answerAfter = ProcessInfo.processInfo.environment["NYUTAG_CALL_ANSWER_AFTER"].flatMap(Double.init) ?? 0
        var acceptAt: Date?
        let center = CallCenter(callEnv)

        var call: CallSession?
        if dial {
            call = await center.dial(roomID: roomID, peer: phone, video: video)
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
            for event in update.response.toDevice {
                guard let message = CallMessage(toDevice: event) else { continue }
                print("call peer: сигнал \(event.type) с устройства телефона")
                await center.absorb(message)
            }
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
                print("call peer: входящий\(session.video ? " видео" : ""), приму через \(answerAfter) с")
                if video { await session.setCamera(true) }
                acceptAt = Date().addingTimeInterval(answerAfter)
            }
            guard let call else { continue }
            if let at = acceptAt, Date() >= at {
                acceptAt = nil
                await call.accept()
            }
            let phase = await call.phase
            if phase != lastPhase {
                print("call peer: фаза \(phase)")
                lastPhase = phase
            }
            if case .live(let since) = phase {
                liveSince = since
                if let video = await call.videoStats, video.sentFrames + video.receivedFrames > 0 {
                    print("call peer: видео: ушло \(video.sentFrames) (ключевых \(video.sentKeyframes), пропущено \(video.skipped), \(video.bitRate / 1000) кбит/с), пришло \(video.receivedFrames), показано \(video.shownFrames) \(video.remoteWidth)×\(video.remoteHeight), битых \(video.brokenFrames), просил ключевых \(video.keyRequestsSent)")
                }
                if let stats = await call.stats {
                    print("call peer: ушло \(stats.sent), пришло \(stats.received), сыграно \(stats.played), потеряно \(stats.lost), слышно \(String(format: "%.3f", stats.outputLevel))")
                }
                if Date().timeIntervalSince(since) > talk { await call.hangUp() }
            }
            if phase.isEnded {
                #expect(liveSince != nil, "разговор не начался: \(phase)")
                if ProcessInfo.processInfo.environment["NYUTAG_CALL_TEXT"] != nil {
                    // Той же сессией шифра, что и сигналы: сравнить, как расширение уведомлений читает текст и отбой.
                    _ = try await machine.sendEncrypted(roomID: roomID, type: EventType.message,
                                                        content: ["msgtype": "m.text", "body": "проверка пуша после звонка"])
                    print("call peer: текст после звонка отправлен")
                }
                return
            }
        }
        Issue.record("звонок не закончился за 3 минуты")
        await call?.hangUp()
    }

    /// NYUTAG_CALL_PEER=once — шифрованное фото «один просмотр» на телефон (проверка защиты от снимка экрана):
    /// ждём, пока телефон откроет его и удалит реплику.
    private func sendViewOnce(_ client: MatrixClient, _ machine: CryptoMachine, roomID: String) async throws {
        let jpeg = try LiveViewOnceTests.jpeg()
        let file = try await client.uploadEncrypted(jpeg, contentType: "image/jpeg")
        let content = Attachment.content(.sealed(file), name: "once.jpg", mimetype: "image/jpeg", size: jpeg.count,
                                         width: 320, height: 240, viewOnce: true)
        let eventID = try await machine.sendEncrypted(roomID: roomID, type: EventType.message, content: content)
        print("call peer: фото «один просмотр» ушло, жду просмотра")
        let deadline = Date().addingTimeInterval(ProcessInfo.processInfo.environment["NYUTAG_CALL_SECONDS"].flatMap(Double.init) ?? 300)
        while Date() < deadline {
            if try await client.event(roomID: roomID, eventID: eventID).isRedacted {
                print("call peer: телефон открыл фото и удалил")
                return
            }
            try await Task.sleep(for: .seconds(3))
        }
        Issue.record("фото не открыто")
        _ = try? await client.redact(roomID: roomID, eventID: eventID)
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
