// Нютаг. Цикл /sync: long-poll, разбор, запись в хранилище, уведомление подписчиков.
// Шифрование подключается через `SyncObserver`: крипто-модуль получает to-device и счётчики ключей отсюда.

import Foundation

public struct SyncUpdate: Sendable {
    public let response: SyncResponse
    /// Комнаты, у которых изменился таймлайн или состояние.
    public let changedRooms: Set<String>
    public let isInitial: Bool
}

public protocol SyncObserver: AnyObject, Sendable {
    func syncDidReceive(_ update: SyncUpdate) async
}

public actor SyncEngine {
    public enum State: Sendable, Equatable {
        case idle
        case running
        case waitingForNetwork(String)
        case stopped(MatrixError?)
    }

    public let client: MatrixClient
    public let store: Store
    public let session: Session

    public private(set) var state: State = .idle
    private var task: Task<Void, Never>?
    private var observers: [ObjectIdentifier: any SyncObserver] = [:]
    private var continuations: [UUID: AsyncStream<SyncUpdate>.Continuation] = [:]

    public var longPollTimeout: Duration = .seconds(30)
    /// Задержка после сетевой ошибки: 1, 2, 4 … до 60 с.
    private var backoff: Duration = .seconds(1)
    /// Цикл ждёт ответа сервера или паузы после ошибки, а не применяет ответ: перезапускать его безопасно.
    private var waiting = false

    public init(client: MatrixClient, store: Store, session: Session) {
        self.client = client
        self.store = store
        self.session = session
    }

    // MARK: Подписка

    public func addObserver(_ observer: any SyncObserver) {
        observers[ObjectIdentifier(observer)] = observer
    }

    public func removeObserver(_ observer: any SyncObserver) {
        observers.removeValue(forKey: ObjectIdentifier(observer))
    }

    /// Поток обновлений для UI. Завершается при остановке движка.
    public func updates() -> AsyncStream<SyncUpdate> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { _ in
                Task { await self.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    // MARK: Цикл

    public func start() {
        guard task == nil else { return }
        state = .running
        task = Task { await loop() }
    }

    public func stop() {
        task?.cancel()
        task = nil
        state = .stopped(nil)
        for continuation in continuations.values { continuation.finish() }
        continuations.removeAll()
    }

    /// Разбудить цикл: после сна приложения длинный запрос мог повиснуть на мёртвом соединении, а пауза после
    /// ошибки — дойти до минуты. Входящий звонок ждёт offer из следующей синхронизации, поэтому по VoIP-пушу и
    /// при возврате на экран начинаем запрос заново. Ответ, который уже применяется, не трогаем.
    public func wake() {
        backoff = .seconds(1)
        guard let task, waiting else { return }
        task.cancel()
        self.task = Task { await loop() }
    }

    /// Один проход /sync, без цикла (для NSE и тестов).
    @discardableResult
    public func syncOnce(timeout: Duration = .zero) async throws(MatrixError) -> SyncUpdate {
        let since = try? await store.syncToken
        let response = try await client.sync(since: since,
                                             filter: since == nil ? SyncFilter.initial() : SyncFilter.incremental(),
                                             timeout: timeout)
        return try await apply(response, isInitial: since == nil)
    }

    private func loop() async {
        while !Task.isCancelled {
            do {
                waiting = true
                let since = try? await store.syncToken
                let response = try await client.sync(since: since,
                                                     filter: since == nil ? SyncFilter.initial() : SyncFilter.incremental(),
                                                     timeout: longPollTimeout)
                // Цикл перезапустили, пока шёл ответ: этот же ответ получит новый цикл.
                if Task.isCancelled { return }
                waiting = false
                try await apply(response, isInitial: since == nil)
                backoff = .seconds(1)
                state = .running
            } catch {
                if Task.isCancelled || error.kind == .cancelled { return }
                if error.isUnknownToken {
                    state = .stopped(error)
                    task = nil
                    return
                }
                state = .waitingForNetwork(String(describing: error.kind))
                waiting = true
                try? await Task.sleep(for: backoff)
                if Task.isCancelled { return }
                waiting = false
                backoff = min(backoff * 2, .seconds(60))
            }
        }
    }

    // MARK: Применение

    func apply(_ response: SyncResponse, isInitial: Bool) async throws(MatrixError) -> SyncUpdate {
        var changed = Set<String>()
        do {
            for (roomID, room) in response.joined {
                try await applyJoined(roomID, room)
                changed.insert(roomID)
            }
            for (roomID, room) in response.invited {
                var record = try await store.room(roomID) ?? RoomRecord(id: roomID, membership: .invite)
                record.membership = .invite
                for event in room.inviteState { try await store.setState(event) }
                try await refreshSummary(&record, stateEvents: room.inviteState)
                try await store.upsert(record)
                changed.insert(roomID)
            }
            for (roomID, room) in response.left {
                var record = try await store.room(roomID) ?? RoomRecord(id: roomID, membership: .leave)
                record.membership = .leave
                for event in room.state { try await store.setState(event) }
                try await store.append(room.timeline.events)
                for event in room.timeline.events where event.isState { try await store.setState(event) }
                try await store.upsert(record)
                changed.insert(roomID)
            }
            for (roomID, room) in response.knocked {
                var record = try await store.room(roomID) ?? RoomRecord(id: roomID, membership: .knock)
                record.membership = .knock
                for event in room.knockState { try await store.setState(event) }
                try await store.upsert(record)
                changed.insert(roomID)
            }
            for event in response.accountData {
                try await store.setAccountData(event.type, content: event.content)
            }
            // Новый m.direct: пересчитать признак личного чата у всех комнат (на первом синке комнаты уже записаны выше).
            if response.accountData.contains(where: { $0.type == EventType.direct }) {
                for var record in try await store.rooms() {
                    let direct = try await isDirect(record.id)
                    guard direct != record.isDirect else { continue }
                    record.isDirect = direct
                    try await store.upsert(record)
                    changed.insert(record.id)
                }
            }
            try await store.setMeta("sync_token", response.nextBatch)
        } catch {
            throw MatrixError(.decoding("хранилище: \(error)"))
        }

        let update = SyncUpdate(response: response, changedRooms: changed, isInitial: isInitial)
        for observer in observers.values {
            await observer.syncDidReceive(update)
        }
        for continuation in continuations.values {
            continuation.yield(update)
        }
        return update
    }

    private func applyJoined(_ roomID: String, _ room: SyncResponse.JoinedRoom) async throws {
        var record = try await store.room(roomID) ?? RoomRecord(id: roomID, membership: .join)
        record.membership = .join
        for event in room.state { try await store.setState(event) }
        try await store.append(room.timeline.events)
        for event in room.timeline.events where event.isState { try await store.setState(event) }
        if let last = room.timeline.events.last?.originServerTS, last > record.latestTS { record.latestTS = last }
        if room.timeline.limited, let prevBatch = room.timeline.prevBatch {
            // Разрыв в таймлайне: запоминаем, откуда докачивать историю.
            record.prevBatch = prevBatch
        } else if record.prevBatch == nil, let prevBatch = room.timeline.prevBatch {
            record.prevBatch = prevBatch
        }
        record.highlightCount = room.unread.highlight
        record.notificationCount = room.unread.notification
        if let heroes = room.summary.heroes { record.heroes = heroes }
        if let joined = room.summary.joinedCount { record.joinedCount = joined }
        if let invited = room.summary.invitedCount { record.invitedCount = invited }
        try await refreshSummary(&record, stateEvents: room.state + room.timeline.events.filter(\.isState))
        for event in room.accountData {
            try await store.setAccountData(event.type, roomID: roomID, content: event.content)
        }
        for event in room.ephemeral where event.type == EventType.receipt {
            try await applyReceipts(roomID: roomID, content: event.content)
        }
        try await store.upsert(record)
    }

    /// Имя, тема, аватар, алиас, шифрование, тип комнаты по пришедшему состоянию (или по сохранённому, если пришло не всё).
    private func refreshSummary(_ record: inout RoomRecord, stateEvents: [Event]) async throws {
        let roomID = record.id
        func content(_ type: String) async throws -> JSONValue? {
            if let fresh = stateEvents.last(where: { $0.type == type && $0.stateKey == "" }) { return fresh.content }
            return try await store.state(roomID, type: type)
        }
        if let name = try await content(EventType.name) { record.name = name["name"]?.string }
        if let topic = try await content(EventType.topic) { record.topic = topic["topic"]?.string }
        if let avatar = try await content(EventType.avatar) { record.avatarURL = avatar["url"]?.string }
        if let alias = try await content(EventType.canonicalAlias) { record.canonicalAlias = alias["alias"]?.string }
        if try await content(EventType.encryption) != nil { record.isEncrypted = true }
        if let create = try await content(EventType.create) { record.isSpace = create["type"]?.string == "m.space" }
        record.isDirect = try await isDirect(roomID, stateEvents: stateEvents)
    }

    /// Личный чат: комната есть в нашем `m.direct` или наш m.room.member помечен `is_direct` (так приходит приглашение).
    private func isDirect(_ roomID: String, stateEvents: [Event] = []) async throws -> Bool {
        var member = stateEvents.last(where: { $0.type == EventType.member && $0.stateKey == session.userID })?.content
        if member == nil { member = try await store.state(roomID, type: EventType.member, stateKey: session.userID) }
        if member?["is_direct"]?.bool == true { return true }
        let direct = try await store.accountData(EventType.direct)?.object ?? [:]
        return direct.values.contains { $0.array?.contains(.string(roomID)) == true }
    }

    private func applyReceipts(roomID: String, content: JSONValue) async throws {
        for (eventID, receipts) in content.object ?? [:] {
            for (userID, data) in receipts["m.read"]?.object ?? [:] {
                try await store.setReceipt(roomID: roomID, userID: userID, eventID: eventID, ts: data["ts"]?.int ?? 0)
            }
            for (userID, data) in receipts["m.read.private"]?.object ?? [:] where userID == session.userID {
                try await store.setReceipt(roomID: roomID, userID: userID, eventID: eventID, ts: data["ts"]?.int ?? 0)
            }
        }
    }
}
