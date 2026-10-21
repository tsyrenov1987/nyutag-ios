// Нютаг. Автоудаление сообщений в чате, как в Telegram. Правило — состояние комнаты `chat.nyutag.autodelete`
// `{"ttl": секунды, "since": мс}`, формат общий с Android. Содержимое шифрованных чатов сервер не видит, поэтому
// удаляют клиенты: истёкшее прячут все, а автор ещё и удаляет свои реплики на сервере.
// Реплики, отправленные до включения, не трогаем; служебные плашки (вход, переименование) остаются.

import Foundation

public struct AutoDelete: Sendable, Equatable {
    public static let day = 86_400
    public static let week = 7 * day
    public static let month = 31 * day
    /// Выкл, день, неделя, месяц.
    public static let choices = [0, day, week, month]

    public let ttl: Int
    public let since: Int

    public init(ttl: Int = 0, since: Int = 0) {
        self.ttl = max(0, ttl)
        self.since = max(0, since)
    }

    public init(json: JSONValue?) {
        self.init(ttl: json?["ttl"]?.int ?? 0, since: json?["since"]?.int ?? 0)
    }

    public var json: JSONValue { ["ttl": .int(ttl), "since": .int(since)] }
    public var isOn: Bool { ttl > 0 }

    /// Новое правило с этого момента; 0 — выключить.
    public static func starting(_ ttl: Int, now: Date = Date()) -> AutoDelete {
        AutoDelete(ttl: ttl, since: ttl > 0 ? Int(now.timeIntervalSince1970 * 1000) : 0)
    }

    /// Чужой нестандартный срок показываем ближайшим вариантом сверху.
    public var choice: Int {
        guard isOn else { return 0 }
        return Self.choices.first { $0 >= ttl } ?? Self.month
    }

    /// Время сервера бывает округлено до секунды вниз — к `since` секунда запаса.
    public func isExpired(_ ts: Int, now: Date = Date()) -> Bool {
        isOn && ts + 999 >= since && ts + ttl * 1000 <= Int(now.timeIntervalSince1970 * 1000)
    }

    /// Когда истечёт ближайшая из показанных реплик: к этому времени ленту надо пересобрать.
    public func nextExpiry(_ items: [FeedItem]) -> Date? {
        guard isOn else { return nil }
        let counted = items.filter { item in !item.isNotice && item.ts + 999 >= since }
        guard let first = counted.map(\.ts).min() else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(first + ttl * 1000) / 1000)
    }

    /// Лента без истёкших реплик.
    public func visible(_ items: [FeedItem], now: Date = Date()) -> [FeedItem] {
        guard isOn else { return items }
        return items.filter { $0.isNotice || !isExpired($0.ts, now: now) }
    }

    /// Свои истёкшие реплики, ещё не удалённые на сервере.
    public func ownToDelete(_ items: [FeedItem], now: Date = Date()) -> [String] {
        guard isOn else { return [] }
        return items.filter { $0.isMine && $0.canDelete && isExpired($0.ts, now: now) }.map(\.id)
    }

    public static func load(roomID: String, store: Store) async throws -> AutoDelete {
        AutoDelete(json: try await store.state(roomID, type: EventType.autodelete, stateKey: ""))
    }
}
