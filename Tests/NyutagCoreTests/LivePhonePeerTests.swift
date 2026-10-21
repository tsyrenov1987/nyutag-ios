// Второе устройство для ручной проверки на iPhone: подтверждение входа по эмодзи.
//   NYUTAG_PHONE_PEER=answer — Мак входит новым устройством основной тестовой учётки и просит подтверждения у её
//                              «Нютаг iPhone»; телефон отвечает (NYUTAG_UI_DEVICE=answer).
//   NYUTAG_PHONE_PEER=ask    — Мак входит в E2EE-учётку, поднимает ключи по коду и ждёт запроса с телефона
//                              (NYUTAG_UI_DEVICE=ask); после сверки отдаёт ему ключи кросс-подписи и бэкапа.
// Эмодзи Мак подтверждает сам, когда они появились. В конце выход: устройство Мака удаляется.

import Foundation
@testable import NyutagCore
import Testing

@Suite(.enabled(if: ProcessInfo.processInfo.environment["NYUTAG_PHONE_PEER"] != nil && LiveE2EEEnv.available,
                "нет NYUTAG_PHONE_PEER"))
struct LivePhonePeerTests {
    @Test func peer() async throws {
        let ask = ProcessInfo.processInfo.environment["NYUTAG_PHONE_PEER"] == "ask"
        let (user, password) = ask ? (LiveE2EEEnv.user!, LiveE2EEEnv.password!) : (LiveEnv.user!, LiveEnv.password!)
        let client = MatrixClient(homeserver: LiveEnv.homeserver!)
        let session = try await client.login(user: user, password: password,
                                             deviceDisplayName: ask ? "Нютаг тест (Мак, с ключами)" : "Нютаг тест (Мак, новый вход)")
        do {
            try await run(client, session, ask: ask)
        } catch {
            print("phone peer: ошибка \(error)")
            try? await client.logout()
            throw error
        }
        try await client.logout()
    }

    private func run(_ client: MatrixClient, _ session: Session, ask: Bool) async throws {
        let store = try Store.inMemory()
        let machine = try await CryptoMachine(client: client, store: store, session: session)
        try await machine.publishKeys(serverCount: nil)
        let engine = SyncEngine(client: client, store: store, session: session)
        await engine.addObserver(machine)
        _ = try await engine.syncOnce()
        if ask {
            try await machine.importCrossSigning(recoveryKey: LiveE2EEEnv.recovery!)
            let backup = try await machine.restoreBackup(recoveryKey: LiveE2EEEnv.recovery!)
            print("phone peer: ключи подняты, из бэкапа \(backup.imported)")
        }

        var id: String?
        if !ask {
            let phones = try await machine.devices(for: [session.userID]).filter { $0.displayName == "Нютаг iPhone" }
            print("phone peer: устройств «Нютаг iPhone» \(phones.count)")
            id = try await machine.requestVerification(userID: session.userID, deviceIDs: phones.map(\.deviceID))
        }
        var confirmed = false, doneAt: Date?
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline {
            _ = try await engine.syncOnce(timeout: .seconds(2))
            if id == nil {
                id = await machine.verificationFlows.first { $0.incoming && $0.otherUserID == session.userID }?.transactionID
                if let id {
                    print("phone peer: пришёл запрос с телефона")
                    try await machine.acceptVerification(id)
                }
                continue
            }
            guard let id, let flow = await machine.verification(id) else { continue }
            switch flow.state {
            case .ready where !ask:
                try await machine.startSas(id)
            case .comparing where !confirmed:
                print("phone peer: эмодзи \(flow.emojiSymbols.map(\.emoji).joined())")
                confirmed = true
                try await machine.confirmSas(id)
            case .done:
                if doneAt == nil { print("phone peer: проверка завершена") }
                doneAt = doneAt ?? Date()
                // Ещё немного синхронизаций: телефон просит секреты уже после done.
                if Date().timeIntervalSince(doneAt!) > 20 { return }
            case .cancelled(let code, let reason):
                print("phone peer: отменено \(code) \(reason)")
                Issue.record("проверка отменена: \(code)")
                return
            default: break
            }
        }
        Issue.record("не дождались конца проверки")
    }
}
