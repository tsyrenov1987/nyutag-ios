// Нютаг. Состояние приложения для экранов: вошли или нет, список чатов, выход. Под капотом хранитель входа,
// синхронизация и крипто-машина; экраны видят только `phase` и `lines`.

import Foundation
import NyutagCore
import Observation
import UserNotifications

@MainActor @Observable
final class AppSession {
    enum Phase: Equatable { case launching, signedOut, signedIn }

    /// Одна на процесс: VoIP-пуш может поднять вход раньше, чем появится экран.
    static let shared = AppSession()

    enum SignInFailure: Error, Equatable { case wrongPassword, tooOften, noNetwork, broken }

    enum KeyFailure: Error, Equatable { case wrongKey, noNetwork, broken }

    enum DeviceCheckFailure: Error, Equatable { case noOtherDevice, noNetwork }

    private(set) var phase: Phase = .launching
    private(set) var lines: [ChatLine] = []
    /// Закреплённые чаты и папки.
    private(set) var layout = ChatLayout()
    /// Код из открытой ссылки-приглашения: экран входа откроет с ним регистрацию.
    var pendingInvite: String?
    /// Комната «Избранного», если уже заведена.
    private(set) var savedRoom: String?
    private(set) var me: String?
    /// Чем кончилась попытка открыть историю паролем; `needsRecoveryKey`/`needsOtherDevice` разберёт экран ключей.
    private(set) var history: PasswordUnlockOutcome?
    /// Растёт на каждой синхронизации: открытый чат по нему перечитывает ленту из базы.
    private(set) var revision = 0
    /// Кто сейчас набирает текст: комната → собеседники, кроме нас.
    private(set) var typing: [String: [String]] = [:]
    /// Проверка своего устройства по эмодзи: этот вход просит подтверждения или подтверждает новый вход.
    private(set) var deviceCheck: VerificationFlow?
    /// Имя другого устройства из списка устройств учётки.
    private(set) var deviceCheckName: String?
    /// Вход подтверждён, ключи переписки ещё идут с другого устройства.
    private(set) var awaitingKeys = false
    /// Окно проверки открыто: его поднимает пришедший запрос или карточка «подтвердите вход».
    var showDeviceCheck = false
    /// Отложенные сообщения всех учёток телефона; отправляем только свои.
    private(set) var scheduled = ScheduledQueue(data: UserDefaults.standard.data(forKey: AppSession.scheduledKey))
    /// Звонки: экран звонка смотрит сюда.
    @ObservationIgnored let calls = CallDesk()

    @ObservationIgnored private let keeper: AccountKeeper?
    @ObservationIgnored private var account: SignedInAccount?
    @ObservationIgnored private var engine: SyncEngine?
    @ObservationIgnored private var machine: CryptoMachine?
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private let opened = OpenedCache()
    /// Свежие события, которые пока нечем расшифровать: в них может быть сигнал звонка.
    @ObservationIgnored private var lockedSignals: [(event: Event, roomID: String)] = []
    /// Скачанные вложения. Зашифрованные лежат на диске шифртекстом, открытым текстом — только в памяти.
    @ObservationIgnored private var media: MediaCache?
    /// Пароль этого входа, только в памяти и только пока история заперта старым ключом: им её перезапрём.
    @ObservationIgnored private var heldPassword: String?
    /// Проверки, которые человек закрыл или которые мы уже начали: второй раз не поднимаем и не начинаем.
    @ObservationIgnored private var closedChecks: Set<String> = []
    @ObservationIgnored private var startedChecks: Set<String> = []
    @ObservationIgnored private var adoptedChecks: Set<String> = []
    /// Сколько записей раскладки ещё в пути: пока они идут, в базе старая версия, её не подхватываем.
    @ObservationIgnored private var layoutWrites = 0
    @ObservationIgnored private var scheduler: Task<Void, Never>?
    @ObservationIgnored private var sendingScheduled: Set<String> = []

    init(keeper: AccountKeeper? = .app()) {
        self.keeper = keeper
    }

    /// Запуск: сохранённый вход поднимаем без сети, список строится из базы сразу.
    func launch() async {
        guard phase == .launching else { return }
        guard let keeper, let account = try? keeper.restore() else {
            phase = .signedOut
            return
        }
        await start(account, password: nil)
    }

    /// Вход по имени, телефону или почте. Телефон и почту сервер Нютага переводит в Matrix ID.
    /// `displayName` — имя нового участника сразу после регистрации: ставим его в профиль до первого /sync.
    func signIn(identifier: String, password: String, displayName: String? = nil) async throws(SignInFailure) {
        guard let keeper else { throw .broken }
        let typed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard await TunnelHub.shared.waitUntilUp() else { throw .noNetwork }
        do {
            var user = typed
            if Self.needsResolve(typed) {
                user = try await NyutagService(client: TunnelHub.shared.makeClient()).resolve(identifier: typed, password: password)
            }
            let account = try await keeper.signIn(homeserver: TunnelHub.coreURL, user: user, password: password,
                                                  deviceName: "Нютаг iPhone")
            if let displayName {
                try? await account.client.setDisplayName(userID: account.session.userID, displayName)
            }
            await start(account, password: password)
        } catch let error as MatrixError {
            #if DEBUG
            print("ui-check: отказ входа: \(error)")
            #endif
            throw Self.failure(error)
        } catch {
            #if DEBUG
            print("ui-check: отказ входа: \(error)")
            #endif
            throw .broken
        }
    }

    func signOut() async {
        guard let account, let keeper else { return }
        await stop()
        if let token = PushDoor.shared.currentToken {
            try? await account.client.removeApplePush(token: token, environment: PushDoor.environment)
        }
        if let token = CallRinger.shared.voipToken {
            try? await account.client.removeVoipPush(token: token, environment: PushDoor.environment)
        }
        try? await keeper.signOut(account)
        Self.rememberHistory(nil, for: account.session.userID)
        try? await media?.clear()
        media = nil
        heldPassword = nil
        self.account = nil
        lines = []
        layout = ChatLayout()
        savedRoom = nil
        setScheduled(scheduled.removingAccount(account.session.userID))
        typing = [:]
        me = nil
        history = nil
        deviceCheck = nil
        deviceCheckName = nil
        awaitingKeys = false
        showDeviceCheck = false
        phase = .signedOut
    }

    // MARK: Старая история

    /// Хранилище ключей заперто прежним ключом восстановления, а не паролем: старые сообщения пока под замком.
    var historyLocked: Bool { history == .needsRecoveryKey }
    /// Пароль этого входа ещё в памяти: ключ сразу перезапрёт хранилище паролем.
    var canRelockHistory: Bool { heldPassword != nil }

    /// Открыть старую историю ключом восстановления. Если пароль этого входа ещё в памяти, хранилище сразу
    /// перезапирается им, и на следующих устройствах хватит пароля. Без пароля (после перезапуска) только открываем.
    func openHistory(recoveryKey: String) async throws(KeyFailure) {
        guard let machine, let me else { throw .broken }
        let key = recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let imported: Int
            if let heldPassword {
                imported = try await machine.relockWithPassword(recoveryKey: key, password: heldPassword)
            } else {
                _ = try await machine.secretStorageKey(recoveryKey: key)
                try await machine.importCrossSigning(recoveryKey: key)
                imported = (try? await machine.restoreBackup(recoveryKey: key).imported) ?? 0
            }
            heldPassword = nil
            history = .opened(imported: imported)
            Self.rememberHistory(nil, for: me)
            await refresh()
            revision += 1
        } catch .wrongRecoveryKey {
            throw .wrongKey
        } catch .server(let error) {
            if case .network = error.kind { throw .noNetwork }
            throw .broken
        } catch {
            throw .broken
        }
    }

    /// Флаг без секретов: карточки «старые сообщения закрыты» и «подтвердите вход» должны пережить перезапуск.
    private static func rememberHistory(_ outcome: PasswordUnlockOutcome?, for userID: String) {
        let key = "nyutag.historyLocked.\(userID)"
        switch outcome {
        case .needsRecoveryKey: UserDefaults.standard.set(true, forKey: key)
        case .needsOtherDevice: UserDefaults.standard.set("device", forKey: key)
        default: UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private static func rememberedHistory(for userID: String) -> PasswordUnlockOutcome? {
        let value = UserDefaults.standard.object(forKey: "nyutag.historyLocked.\(userID)")
        if value as? String == "device" { return .needsOtherDevice }
        return value as? Bool == true ? .needsRecoveryKey : nil
    }

    // MARK: Подтверждение с другого устройства

    /// Этот вход ещё не подтверждён: ключей кросс-подписи нет, хранилища ключей на сервере тоже.
    var needsOtherDevice: Bool { history == .needsOtherDevice }

    /// Попросить подтверждение у своих других устройств: там появится запрос, потом те же эмодзи.
    func askOtherDevice() async throws(DeviceCheckFailure) {
        guard let machine, let me else { throw .noNetwork }
        do {
            let id = try await machine.requestVerification(userID: me)
            deviceCheck = await machine.verification(id)
            deviceCheckName = nil
        } catch .badPayload {
            throw .noOtherDevice
        } catch {
            throw .noNetwork
        }
    }

    /// «Это я»: согласиться на запрос нового входа.
    func acceptDeviceCheck() async {
        guard let machine, let id = deviceCheck?.transactionID else { return }
        // Свои задачи: экран может закрыться или перерисоваться посреди обмена, а недосланный шаг повесит проверку.
        try? await Task { try await machine.acceptVerification(id) }.value
        await followDeviceCheck()
    }

    func confirmEmoji() async {
        guard let machine, let id = deviceCheck?.transactionID else { return }
        do {
            try await Task { try await machine.confirmSas(id) }.value
        } catch {
            #if DEBUG
            print("ui-check: сверка не закончена: \(error)")
            #endif
        }
        await followDeviceCheck()
    }

    /// Эмодзи разные или «это не я»: проверка отменяется у обеих сторон.
    func rejectDeviceCheck(mismatch: Bool) async {
        guard let machine, let id = deviceCheck?.transactionID else { return }
        await Task {
            await machine.cancelVerification(id, code: mismatch ? "m.mismatched_sas" : "m.user",
                                             reason: mismatch ? "Эмодзи не совпали" : "Отменено пользователем")
        }.value
        await followDeviceCheck()
    }

    /// Окно закрыто: незаконченная проверка отменяется.
    func closeDeviceCheck() async {
        showDeviceCheck = false
        guard let flow = deviceCheck else { return }
        closedChecks.insert(flow.transactionID)
        switch flow.state {
        case .done, .cancelled: break
        default: await machine?.cancelVerification(flow.transactionID)
        }
        deviceCheck = nil
        deviceCheckName = nil
    }

    /// После каждой синхронизации и каждого действия: новое состояние проверки, пришедший запрос, ключи.
    private func followDeviceCheck() async {
        guard let machine, let me else { return }
        if let current = deviceCheck {
            if let fresh = await machine.verification(current.transactionID), fresh != current { deviceCheck = fresh }
        } else if let incoming = await machine.verificationFlows.first(where: {
            $0.incoming && $0.otherUserID == me && $0.roomID == nil && $0.state == .requested
                && !closedChecks.contains($0.transactionID)
        }) {
            deviceCheck = incoming
            showDeviceCheck = true
        }
        guard let flow = deviceCheck else { return }
        if deviceCheckName == nil, let other = flow.otherDeviceID {
            let device = try? await machine.devices(for: [me]).first { $0.deviceID == other }
            deviceCheckName = device?.displayName.flatMap { $0.isEmpty ? nil : $0 }
        }
        if flow.state == .ready, startedChecks.insert(flow.transactionID).inserted {
            Task { await startEmoji(flow.transactionID, afterPause: flow.incoming) }
        }
        if flow.state == .done, history == .needsOtherDevice || history == .needsRecoveryKey,
           adoptedChecks.insert(flow.transactionID).inserted {
            awaitingKeys = true
            Task { await adoptKeysFromOtherDevice() }
        }
    }

    /// Начинает тот, кто просил; на чужой запрос сначала ждём начала оттуда и только потом начинаем сами.
    private func startEmoji(_ id: String, afterPause: Bool) async {
        guard let machine else { return }
        if afterPause { try? await Task.sleep(for: .seconds(3)) }
        if await machine.verification(id)?.state == .ready { try? await machine.startSas(id) }
        if deviceCheck?.transactionID == id, let fresh = await machine.verification(id) { deviceCheck = fresh }
    }

    /// Ключи кросс-подписи и бэкапа идут с проверенного устройства отдельными сообщениями. Ждём их до 30 секунд.
    /// Хранилища на сервере не было — заводим его под паролем этого входа, и следующим входам хватит пароля.
    private func adoptKeysFromOtherDevice() async {
        guard let machine, let me else { return }
        for _ in 0..<30 {
            if await machine.hasCrossSigningKeys, await machine.hasBackupKey { break }
            try? await Task.sleep(for: .seconds(1))
        }
        guard await machine.hasCrossSigningKeys else {
            awaitingKeys = false
            return
        }
        if history == .needsOtherDevice, let heldPassword {
            history = (try? await machine.unlockWithPassword(heldPassword)) ?? .opened(imported: 0)
        } else {
            history = .opened(imported: 0)
        }
        #if DEBUG
        print("ui-check: ключи с другого устройства пришли, история: \(history.map { "\($0)" } ?? "?")")
        #endif
        heldPassword = nil
        awaitingKeys = false
        Self.rememberHistory(nil, for: me)
        await refresh()
        revision += 1
    }

    // MARK: Открытый чат

    func feed(_ roomID: String, limit: Int) async -> [FeedItem] {
        guard let account, let me else { return [] }
        return (try? await ChatFeed.items(roomID: roomID, store: account.store, me: me, limit: limit, decrypt: opener())) ?? []
    }

    /// Докачать историю назад. `false` — дальше начало чата (или нет сети).
    func older(_ roomID: String) async -> Bool {
        guard let engine else { return false }
        let page = try? await engine.backfill(roomID: roomID)
        return page?.hasMore ?? false
    }

    /// Отправка текста, в шифрованный чат — через машину. Тот же `transactionID` при повторе сервер не дублирует.
    func send(_ text: String, to roomID: String, replyTo: String?, transactionID: String) async -> String? {
        var content: [String: JSONValue] = ["msgtype": "m.text", "body": .string(text)]
        if let replyTo { content["m.relates_to"] = ["m.in_reply_to": ["event_id": .string(replyTo)]] }
        return await post(EventType.message, .object(content), to: roomID, transactionID: transactionID)
    }

    /// Новый текст своей реплики.
    func edit(_ eventID: String, text: String, in roomID: String) async -> Bool {
        await post(EventType.message, Relations.edit(of: eventID, text: text), to: roomID) != nil
    }

    /// Удалить реплику у всех.
    func delete(_ eventID: String, in roomID: String) async -> Bool {
        (try? await account?.client.redact(roomID: roomID, eventID: eventID)) != nil
    }

    /// Таймер автоудаления чата, как его видит база после последнего /sync.
    func autoDelete(_ roomID: String) async -> AutoDelete {
        guard let account else { return AutoDelete() }
        return (try? await AutoDelete.load(roomID: roomID, store: account.store)) ?? AutoDelete()
    }

    /// Новый таймер с этого момента; `nil` — сервер не принял (например, не хватает прав в группе).
    func setAutoDelete(_ ttl: Int, in roomID: String) async -> AutoDelete? {
        guard let account else { return nil }
        let rule = AutoDelete.starting(ttl)
        do {
            _ = try await account.client.setState(roomID: roomID, type: EventType.autodelete, content: rule.json)
            return rule
        } catch {
            #if DEBUG
            print("ui-check: таймер не записан: \(error)")
            #endif
            return nil
        }
    }

    /// Реакция: нашей с таким ключом ещё нет — ставим, есть — снимаем.
    func toggleReaction(_ key: String, on item: FeedItem, in roomID: String) async -> Bool {
        if let mine = item.reactions.first(where: { $0.key == key })?.myEventID { return await delete(mine, in: roomID) }
        return await post(EventType.reaction, Relations.reaction(to: item.id, key: key), to: roomID) != nil
    }

    /// Событие в комнату; в шифрованную — через машину.
    private func post(_ type: String, _ content: JSONValue, to roomID: String,
                      transactionID: String = TransactionID.make()) async -> String? {
        guard let account else { return nil }
        let encrypted = (try? await account.store.room(roomID))?.isEncrypted ?? false
        if encrypted {
            guard let machine else { return nil }
            do {
                return try await machine.sendEncrypted(roomID: roomID, type: type, content: content, transactionID: transactionID)
            } catch {
                #if DEBUG
                print("ui-check: шифрованная отправка \(type) не прошла: \(error)")
                #endif
                return nil
            }
        }
        return try? await account.client.send(roomID: roomID, type: type, content: content, transactionID: transactionID)
    }

    /// Файл или картинка в чат: в шифрованный — шифртекстом (ключ уедет внутри реплики), в открытый — как есть.
    func sendAttachment(_ file: OutgoingFile, to roomID: String, transactionID: String) async -> String? {
        guard let account else { return nil }
        let encrypted = (try? await account.store.room(roomID))?.isEncrypted ?? false
        let source: Attachment.Source
        do {
            if encrypted {
                source = .sealed(try await account.client.uploadEncrypted(file.data, contentType: file.mimetype))
            } else {
                source = .plain(try await account.client.uploadMedia(file.data, contentType: file.mimetype, filename: file.name))
            }
        } catch {
            #if DEBUG
            print("ui-check: загрузка вложения не прошла: \(error)")
            #endif
            return nil
        }
        let content = Attachment.content(source, name: file.name, mimetype: file.mimetype, size: file.data.count,
                                         width: file.width, height: file.height, viewOnce: file.viewOnce)
        return await post(EventType.message, content, to: roomID, transactionID: transactionID)
    }

    /// Содержимое вложения, уже расшифрованное. `preview` — миниатюра для ленты, если она есть.
    func attachmentData(_ attachment: Attachment, preview: Bool) async -> Data? {
        guard let media else { return nil }
        switch preview ? (attachment.thumbnail ?? attachment.source) : attachment.source {
        case .sealed(let file):
            return try? await media.decrypted(file)
        case .plain(let mxc):
            // Открытую картинку без своей миниатюры уменьшит сервер.
            let size = preview && attachment.thumbnail == nil ? (width: 800, height: 800) : nil
            return try? await media.data(mxc, size: size)
        }
    }

    /// «Набираю текст»: сервер сам снимет отметку через 20 секунд, если не продлить.
    func setTyping(_ typing: Bool, in roomID: String) async {
        guard let account, let me else { return }
        try? await account.client.setTyping(roomID: roomID, userID: me, typing: typing)
    }

    /// Отметка прочтения: публичная, чтобы у собеседника загорелись две галочки.
    func markRead(_ roomID: String, upTo eventID: String) async {
        try? await account?.client.setReadMarkers(roomID: roomID, fullyRead: eventID, read: eventID)
    }

    // MARK: Отложенные

    static let scheduledKey = "nyutag.scheduled"

    func schedule(_ text: String, in roomID: String, at date: Date) {
        guard let me else { return }
        setScheduled(scheduled.adding(ScheduledMessage(account: me, roomID: roomID, body: text, sendAt: date)))
    }

    func sendScheduledNow(_ id: String) { setScheduled(scheduled.sendingNow(id)) }
    func dropScheduled(_ id: String) { setScheduled(scheduled.removing(id)) }

    private func setScheduled(_ fresh: ScheduledQueue) {
        guard fresh != scheduled else { return }
        scheduled = fresh
        UserDefaults.standard.set(fresh.data, forKey: Self.scheduledKey)
        Task { await Self.syncReminders(fresh) }
        Task { await sendDueScheduled() }
    }

    /// Обход раз в 5 секунд, пока приложение открыто: в фоне задача спит вместе с ним и догоняет при возврате.
    private func startScheduler() {
        scheduler?.cancel()
        scheduler = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sendDueScheduled()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func sendDueScheduled() async {
        guard let account, let me else { return }
        for message in scheduled.due(account: me) where !sendingScheduled.contains(message.id) {
            guard let room = try? await account.store.room(message.roomID) else { continue }
            if room.membership != .join {
                // Из чата вышли — отправлять некуда.
                setScheduled(scheduled.removing(message.id))
                continue
            }
            sendingScheduled.insert(message.id)
            let eventID = await send(message.body, to: message.roomID, replyTo: nil, transactionID: message.transactionID)
            sendingScheduled.remove(message.id)
            #if DEBUG
            print("ui-check: отложенное \(eventID == nil ? "не ушло, повторю" : "ушло")")
            #endif
            if eventID != nil { setScheduled(scheduled.removing(message.id)) }
        }
    }

    /// Напоминание через 2 минуты после срока: если приложение было закрыто и сообщение не ушло,
    /// человек откроет Нютаг и обход его отправит. Ушло или удалено — напоминание снимаем.
    private static func syncReminders(_ queue: ScheduledQueue) async {
        let center = UNUserNotificationCenter.current()
        let prefix = "nyutag.scheduled."
        let wanted = Set(queue.messages.map { prefix + $0.id })
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending.filter { !wanted.contains($0) })
        let delivered = await center.deliveredNotifications().map(\.request.identifier).filter { $0.hasPrefix(prefix) }
        center.removeDeliveredNotifications(withIdentifiers: delivered.filter { !wanted.contains($0) })
        let words = Words()
        for message in queue.messages where !pending.contains(prefix + message.id) {
            let content = UNMutableNotificationContent()
            content.title = words(.scheduledReminder)
            content.body = String(message.body.prefix(80))
            content.userInfo = ["room_id": message.roomID]
            let wait = max(1, message.date.timeIntervalSinceNow + 120)
            let request = UNNotificationRequest(identifier: prefix + message.id, content: content,
                                                trigger: UNTimeIntervalNotificationTrigger(timeInterval: wait, repeats: false))
            try? await center.add(request)
        }
    }

    // MARK: Закреп и папки

    func setPinned(_ roomID: String, _ pinned: Bool) async { await change(layout.pinning(roomID, pinned)) }
    func addFolder(_ name: String, with roomID: String?) async { await change(layout.addingFolder(name: name, with: roomID)) }
    func renameFolder(_ id: String, to name: String) async { await change(layout.renamingFolder(id, to: name)) }
    func deleteFolder(_ id: String) async { await change(layout.removingFolder(id)) }
    func place(_ roomID: String, in folderID: String, _ inside: Bool) async { await change(layout.placing(roomID, in: folderID, inside)) }

    /// Показываем сразу; если сервер не принял, возвращаем как было.
    private func change(_ fresh: ChatLayout) async {
        guard let account, let me, fresh != layout else { return }
        let old = layout
        layout = fresh
        layoutWrites += 1
        defer { layoutWrites -= 1 }
        do {
            try await account.client.save(fresh, userID: me, store: account.store)
        } catch {
            #if DEBUG
            print("ui-check: раскладка не записана: \(error)")
            #endif
            if layout == fresh { layout = old }
        }
    }

    // MARK: Избранное

    /// Чат с собой: известный — открываем (имя по умолчанию переводим на язык телефона), иначе заводим новый.
    func openSaved(name: String, topic: String) async -> String? {
        guard let account, let me else { return nil }
        let known = try? await SavedMessages.load(store: account.store)
        if let known, let room = try? await account.store.room(known), room.membership == .join || room.membership == .invite {
            if room.membership == .invite { _ = try? await account.client.join(known) }
            if let title = lines.first(where: { $0.id == known })?.title, SavedMessages.needsRename(title, to: name) {
                _ = try? await account.client.setState(roomID: known, type: EventType.name, content: ["name": .string(name)])
            }
            savedRoom = known
            return known
        }
        let roomID = try? await account.client.createSavedMessages(name: name, topic: topic, userID: me, store: account.store)
        #if DEBUG
        print("ui-check: избранное \(roomID == nil ? "не создано" : "создано")")
        #endif
        if let roomID { savedRoom = roomID }
        return roomID
    }

    // MARK: Профиль

    func profile(of userID: String) async -> Profile? {
        guard let account else { return nil }
        return try? await account.client.profile(userID: userID)
    }

    /// Имя и «о себе»: отправляем только то, что изменилось.
    func saveProfile(name: String, about: ProfileAbout, was old: Profile) async -> Bool {
        guard let account, let me else { return false }
        do {
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty, clean != old.displayName { try await account.client.setDisplayName(userID: me, clean) }
            let edits = about.edits(from: ProfileAbout(profile: old))
            if !edits.isEmpty {
                let api = try await account.client.profileFieldsAPI()
                try await account.client.applyProfileEdits(userID: me, edits, api: api)
            }
            return true
        } catch {
            #if DEBUG
            print("ui-check: профиль не сохранён: \(error)")
            #endif
            return false
        }
    }

    /// Собеседник личного чата.
    func partner(in roomID: String) async -> String? {
        guard let account, let me else { return nil }
        return try? await People.partner(roomID: roomID, store: account.store, me: me)
    }

    // MARK: Приглашения

    enum InviteFailure: Error { case limit, noNetwork, broken }

    func createInvite() async throws(InviteFailure) -> InviteCode {
        guard let account else { throw .broken }
        do {
            return try await NyutagService(client: account.client).createInvite()
        } catch {
            throw Self.inviteFailure(error)
        }
    }

    func myInvites() async -> [(invite: InviteCode, usedBy: String?)]? {
        guard let account else { return nil }
        return try? await NyutagService(client: account.client).invites()
    }

    func revokeInvite(_ code: String) async -> Bool {
        guard let account else { return false }
        return (try? await NyutagService(client: account.client).revokeInvite(code)) != nil
    }

    private static func inviteFailure(_ error: MatrixError) -> InviteFailure {
        switch error.errcode {
        case "NYUTAG_INVITE_LIMIT", "M_LIMIT_EXCEEDED": return .limit
        default:
            if case .network = error.kind { return .noNetwork }
            return .broken
        }
    }

    // MARK: Контакты

    /// С кем уже есть личный чат.
    func knownPeople() async -> [Person] {
        guard let account, let me else { return [] }
        return (try? await People.known(store: account.store, me: me)) ?? []
    }

    /// Номера из книжки → кто из них в Нютаге. Сервер берёт до 500 номеров за раз.
    func lookup(phones: [String]) async -> [String: String] {
        guard let account else { return [:] }
        let service = NyutagService(client: account.client)
        var found: [String: String] = [:]
        for start in stride(from: 0, to: phones.count, by: 500) {
            let part = Array(phones[start..<min(start + 500, phones.count)])
            guard let matches = try? await service.lookup(phones: part) else { break }
            found.merge(matches) { first, _ in first }
        }
        return found
    }

    func searchPeople(_ term: String) async -> [Person] {
        guard let account, let me else { return [] }
        var found = (try? await account.client.searchUsers(term)) ?? []
        if let server = me.split(separator: ":", maxSplits: 1).last,
           let exact = try? await account.client.person(nick: term, server: String(server)),
           !found.contains(where: { $0.userID == exact.userID }) {
            found.insert(exact, at: 0)
        }
        return found.filter { $0.userID != me }
    }

    /// Личный чат с человеком: свой, если уже есть (приглашение принимаем), иначе новый шифрованный.
    func openDirect(with userID: String) async -> String? {
        guard let account, let me else { return nil }
        if let known = await knownPeople().first(where: { $0.userID == userID }), let roomID = known.directRoom {
            if (try? await account.store.room(roomID))?.membership == .invite {
                guard (try? await account.client.join(roomID)) != nil else { return nil }
            }
            return roomID
        }
        let roomID = try? await account.client.createDirectRoom(userID: me, with: userID)
        #if DEBUG
        print("ui-check: личный чат \(roomID == nil ? "не создан" : "создан")")
        #endif
        return roomID
    }

    #if DEBUG
    /// Самопроверка: свой шифрованный чат без участников, чтобы пробные реплики никому не уходили.
    func ensurePrivateRoom(named name: String) async {
        guard let account, !lines.contains(where: { $0.title == name }) else { return }
        let id = try? await account.client.createRoom(.init(name: name))
        print("ui-check: свой чат \(id == nil ? "не создан" : "создан")")
    }
    #endif

    // MARK: Внутреннее

    /// Расшифровка для списка и ленты через общий кэш: одно событие не открываем дважды.
    private func opener() -> @Sendable (Event, String) async -> Event? {
        let machine = machine
        let opened = opened
        return { event, roomID in
            guard let id = event.eventID else { return nil }
            if let known = await opened.get(id) { return known }
            guard let machine, let clear = try? await machine.decrypt(event, roomID: roomID).event else { return nil }
            await opened.put(clear, id: id)
            return clear
        }
    }

    private func start(_ account: SignedInAccount, password: String?) async {
        self.account = account
        me = account.session.userID
        let engine = SyncEngine(client: account.client, store: account.store, session: account.session)
        self.engine = engine
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        media = try? MediaCache(client: account.client, directory: caches.appending(path: "media", directoryHint: .isDirectory))
        phase = .signedIn
        await refresh()
        do {
            let machine = try await CryptoMachine(client: account.client, store: account.store, session: account.session)
            self.machine = machine
            await engine.addObserver(machine)
            _ = try? await machine.publishKeys(serverCount: nil)
            if let password {
                // Пароль уже проверен сервером: им же запираем или открываем хранилище ключей.
                history = try? await machine.unlockWithPassword(password)
                if history == .needsRecoveryKey || history == .needsOtherDevice { heldPassword = password }
                Self.rememberHistory(history, for: account.session.userID)
                #if DEBUG
                print("ui-check: история по паролю: \(history.map { "\($0)" } ?? "ошибка")")
                #endif
            } else if let remembered = Self.rememberedHistory(for: account.session.userID) {
                history = remembered
            }
        } catch {
            // Без машины переписка в шифрованных чатах остаётся под замком, остальное работает.
        }
        Task { [weak self] in await self?.enablePush() }
        if let voip = CallRinger.shared.voipToken { Task { [weak self] in await self?.enableVoip(voip) } }
        #if DEBUG
        print("ui-check: это устройство \(account.session.deviceID)")
        #endif
        startCalls(account)
        startScheduler()
        let updates = await engine.updates()
        pump = Task { [weak self] in
            for await update in updates {
                #if DEBUG
                if !update.response.toDevice.isEmpty, let failure = await self?.machine?.lastToDeviceFailure {
                    print("ui-check: to-device сбой: \(failure)")
                }
                #endif
                self?.noteTyping(update.response)
                await self?.absorbCalls(update.response)
                await self?.followDeviceCheck()
                await self?.refresh()
                self?.revision += 1
            }
        }
        await engine.start()
        await refresh()
    }

    /// Пушер звонков: токен PushKit приходит сам по себе, раньше или позже входа. Вместе с ним — правило,
    /// по которому сервер вообще отдаёт будильник шлюзу.
    func enableVoip(_ token: Data) async {
        guard let client = account?.client else { return }
        let language = Locale.current.language.languageCode?.identifier ?? "ru"
        do {
            try await client.ensureRingPushRule()
            try await client.registerVoipPush(token: token, environment: PushDoor.environment,
                                              deviceName: "Нютаг iPhone", language: language)
            #if DEBUG
            print("ui-check: VoIP-пушер записан, \(ApplePusher.voipAppID(PushDoor.environment))")
            #endif
        } catch {
            #if DEBUG
            print("ui-check: VoIP-пушер не записан: \(error)")
            #endif
        }
    }

    /// Пушер на сервере: при каждом запуске, повтор с тем же токеном только обновляет запись.
    private func enablePush() async {
        guard let client = account?.client, let token = await PushDoor.shared.requestToken() else { return }
        let language = Locale.current.language.languageCode?.identifier ?? "ru"
        do {
            try await client.registerApplePush(token: token, environment: PushDoor.environment,
                                               deviceName: "Нютаг iPhone", language: language)
            #if DEBUG
            print("ui-check: пушер записан, \(ApplePusher.appID(PushDoor.environment))")
            #endif
        } catch {
            #if DEBUG
            print("ui-check: пушер не записан: \(error)")
            #endif
        }
    }

    // MARK: Звонки

    enum CallKind { case none, direct, group }

    /// Позвонить в комнату: один на один, если в ней ровно один кроме нас, иначе групповой (только голос).
    func startCall(in roomID: String, video: Bool = false) async {
        switch await callKind(roomID) {
        case .direct:
            guard let peer = await callPeer(roomID) else { return }
            await calls.dial(roomID: roomID, peer: peer, video: video)
        case .group:
            await calls.dialGroup(roomID: roomID)
        case .none:
            break
        }
    }

    /// Групповой — только в шифрованной комнате: ключи кадров идут шифром комнаты.
    func callKind(_ roomID: String) async -> CallKind {
        guard let account, let me else { return .none }
        let members = (try? await account.store.state(roomID, type: EventType.member)) ?? []
        let others = members.filter {
            $0.stateKey != me && ["join", "invite"].contains($0.content["membership"]?.string ?? "")
        }
        if others.count == 1 { return .direct }
        let encrypted = (try? await account.store.room(roomID))?.isEncrypted ?? false
        return others.count > 1 && encrypted ? .group : .none
    }

    /// Имя участника комнаты для экрана группового звонка.
    func memberName(_ roomID: String, _ user: String) async -> String {
        let members = (try? await account?.store.state(roomID, type: EventType.member)) ?? []
        let name = members.first { $0.stateKey == user }?.content["displayname"]?.string ?? ""
        return name.isEmpty ? ChatDigest.localpart(user) : name
    }

    func callPeer(_ roomID: String) async -> String? {
        guard let account, let me else { return nil }
        let members = (try? await account.store.state(roomID, type: EventType.member)) ?? []
        let others = members.filter {
            $0.stateKey != me && ["join", "invite"].contains($0.content["membership"]?.string ?? "")
        }
        return others.count == 1 ? others[0].stateKey : nil
    }

    private struct CallPostFailure: Error {}

    private func startCalls(_ account: SignedInAccount) {
        let client = account.client
        // Звук включает CallKit; без него (симулятор) — сами.
        let ownAudio = CallRinger.shared.bypass
        var env = CallEnvironment(
            me: account.session.userID, deviceID: account.session.deviceID,
            post: { [weak self] signal, roomID in
                guard let self, await self.postSignal(signal, to: roomID) else { throw CallPostFailure() }
            },
            openTransport: { slot in await RelayLink.open(client: client, slot: slot) },
            makeVoice: {
                DeviceVoice(managesSession: ownAudio, log: { line in
                    #if DEBUG
                    print("ui-check: \(line)")
                    #endif
                })
            })
        env.makeCamera = {
            #if DEBUG
            if ProcessInfo.processInfo.environment["NYUTAG_UI_FAKE_CAMERA"] != nil { return StripeCamera() }
            #endif
            guard DeviceCamera.available else { return nil }
            return DeviceCamera(log: { line in
                #if DEBUG
                print("ui-check: \(line)")
                #endif
            })
        }
        calls.name = { [weak self] roomID, peer in
            let title = self?.lines.first { $0.id == roomID }?.title ?? ""
            return title.isEmpty ? peer : title
        }
        calls.memberName = { [weak self] roomID, user in
            await self?.memberName(roomID, user) ?? ChatDigest.localpart(user)
        }
        calls.attach(CallCenter(env))
        #if DEBUG
        if let room = ProcessInfo.processInfo.environment["NYUTAG_UI_CALL_ROOM"] {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                await self?.startCall(in: room, video: ProcessInfo.processInfo.environment["NYUTAG_UI_CALL_VIDEO"] != nil)
            }
        }
        #endif
    }

    /// Будильник идёт открытым всегда (по нему шлюз шлёт VoIP-пуш), остальное — как обычные события комнаты.
    private func postSignal(_ signal: CallSignal, to roomID: String) async -> Bool {
        guard let account else { return false }
        if !signal.wantsRoomEncryption {
            return (try? await account.client.send(roomID: roomID, type: signal.eventType, content: signal.content,
                                                    transactionID: TransactionID.make())) != nil
        }
        let sent = await post(signal.eventType, signal.content, to: roomID) != nil
        #if DEBUG
        print("ui-check: сигнал \(signal.eventType) \(sent ? "ушёл" : "не ушёл")")
        #endif
        return sent
    }

    /// Сигналы звонков из свежей синхронизации. Старше двух минут не смотрим: звонок уже кончился, а расшифровка
    /// всей истории первой синхронизации стоила бы дорого. Ключ сеанса нового устройства собеседника часто
    /// приходит синхронизацией позже самого сигнала: нераскрытые свежие события пробуем снова при следующих.
    private func absorbCalls(_ response: SyncResponse) async {
        let open = opener()
        let fresh = Int(Date().timeIntervalSince1970 * 1000) - 120_000
        let waiting = lockedSignals.filter { ($0.event.originServerTS ?? 0) > fresh }
        lockedSignals = []
        var arrived: [(event: Event, roomID: String)] = waiting
        for (roomID, room) in response.joined {
            for event in room.timeline.events where (event.originServerTS ?? 0) > fresh {
                arrived.append((event, roomID))
            }
        }
        for (event, roomID) in arrived {
            var clear = event
            if event.type == EventType.encrypted {
                guard let opened = await open(event, roomID) else {
                    if lockedSignals.count < 64 { lockedSignals.append((event, roomID)) }
                    #if DEBUG
                    print("ui-check: свежее зашифрованное из \(roomID.prefix(8))… не раскрыто")
                    #endif
                    continue
                }
                clear = opened
            }
            guard let message = CallMessage(clear, roomID: roomID) else { continue }
            #if DEBUG
            if waiting.contains(where: { $0.event.eventID == event.eventID }) {
                print("ui-check: сигнал \(clear.type) раскрыт со второй попытки")
            }
            print("ui-check: пришёл сигнал \(clear.type) из \(roomID.prefix(8))…")
            #endif
            await calls.absorb(message)
        }
    }

    private func noteTyping(_ response: SyncResponse) {
        guard let me else { return }
        for (roomID, room) in response.joined {
            guard let who = Relations.typing(room.ephemeral, me: me) else { continue }
            if who.isEmpty { typing.removeValue(forKey: roomID) } else if typing[roomID] != who { typing[roomID] = who }
        }
    }

    private func stop() async {
        await calls.detach()
        scheduler?.cancel()
        scheduler = nil
        pump?.cancel()
        pump = nil
        await engine?.stop()
        engine = nil
        machine = nil
    }

    private func refresh() async {
        guard let account, let me else { return }
        let fresh = try? await ChatDigest.lines(store: account.store, me: me, decrypt: opener())
        if let fresh, fresh != lines { lines = fresh }
        if layoutWrites == 0, let saved = try? await ChatLayout.load(store: account.store), layoutWrites == 0, saved != layout {
            layout = saved
        }
        if let saved = try? await SavedMessages.load(store: account.store), saved != savedRoom { savedRoom = saved }
    }

    static func needsResolve(_ identifier: String) -> Bool {
        if identifier.hasPrefix("@") { return false }
        if identifier.contains("@") { return true }
        let digits = identifier.filter(\.isNumber)
        return digits.count >= 7 && identifier.allSatisfy { $0.isNumber || "+-() ".contains($0) }
    }

    static func failure(_ error: MatrixError) -> SignInFailure {
        if error.status == 429 || error.errcode == "M_LIMIT_EXCEEDED" { return .tooOften }
        if error.errcode == "M_FORBIDDEN" || error.errcode == "M_NOT_FOUND" || error.status == 403 { return .wrongPassword }
        if case .network = error.kind { return .noNetwork }
        // Закрытый путь (туннель упал между проверкой и запросом) URLSession отдаёт как отмену.
        if case .cancelled = error.kind { return .noNetwork }
        return .broken
    }
}

/// Готовый к отправке файл: картинка уже пережата, у неё известны размеры.
struct OutgoingFile: Sendable {
    let data: Data
    let name: String
    let mimetype: String
    var width: Int?
    var height: Int?
    /// Исчезающее фото: один просмотр у получателя.
    var viewOnce = false
}

/// Расшифрованные последние реплики: список перестраивается на каждый /sync, расшифровывать заново незачем.
/// Неудачи не запоминаем: ключ может прийти со следующей синхронизацией.
actor OpenedCache {
    private var events: [String: Event] = [:]

    func get(_ eventID: String) -> Event? { events[eventID] }

    func put(_ event: Event, id: String) {
        if events.count > 2000 { events.removeAll(keepingCapacity: true) }
        events[id] = event
    }
}
