// Нютаг. Состояние приложения для экранов: вошли или нет, список чатов, выход. Под капотом хранитель входа,
// синхронизация и крипто-машина; экраны видят только `phase` и `lines`.

import Foundation
import NyutagCore
import Observation

@MainActor @Observable
final class AppSession {
    enum Phase: Equatable { case launching, signedOut, signedIn }

    enum SignInFailure: Error, Equatable { case wrongPassword, tooOften, noNetwork, broken }

    enum KeyFailure: Error, Equatable { case wrongKey, noNetwork, broken }

    enum DeviceCheckFailure: Error, Equatable { case noOtherDevice, noNetwork }

    private(set) var phase: Phase = .launching
    private(set) var lines: [ChatLine] = []
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

    @ObservationIgnored private let keeper: AccountKeeper?
    @ObservationIgnored private var account: SignedInAccount?
    @ObservationIgnored private var engine: SyncEngine?
    @ObservationIgnored private var machine: CryptoMachine?
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private let opened = OpenedCache()
    /// Скачанные вложения. Зашифрованные лежат на диске шифртекстом, открытым текстом — только в памяти.
    @ObservationIgnored private var media: MediaCache?
    /// Пароль этого входа, только в памяти и только пока история заперта старым ключом: им её перезапрём.
    @ObservationIgnored private var heldPassword: String?
    /// Проверки, которые человек закрыл или которые мы уже начали: второй раз не поднимаем и не начинаем.
    @ObservationIgnored private var closedChecks: Set<String> = []
    @ObservationIgnored private var startedChecks: Set<String> = []
    @ObservationIgnored private var adoptedChecks: Set<String> = []

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
        try? await keeper.signOut(account)
        Self.rememberHistory(nil, for: account.session.userID)
        try? await media?.clear()
        media = nil
        heldPassword = nil
        self.account = nil
        lines = []
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
            return try? await machine.sendEncrypted(roomID: roomID, type: type, content: content, transactionID: transactionID)
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
                                         width: file.width, height: file.height)
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
        let updates = await engine.updates()
        pump = Task { [weak self] in
            for await update in updates {
                self?.noteTyping(update.response)
                await self?.followDeviceCheck()
                await self?.refresh()
                self?.revision += 1
            }
        }
        await engine.start()
        await refresh()
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

    private func noteTyping(_ response: SyncResponse) {
        guard let me else { return }
        for (roomID, room) in response.joined {
            guard let who = Relations.typing(room.ephemeral, me: me) else { continue }
            if who.isEmpty { typing.removeValue(forKey: roomID) } else if typing[roomID] != who { typing[roomID] = who }
        }
    }

    private func stop() async {
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
