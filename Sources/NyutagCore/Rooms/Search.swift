// Нютаг. Поиск по сообщениям. Шифрованные реплики в базе лежат закрытыми, поэтому поиск идёт по своему индексу
// (`search_text`): фоновый проход расшифровывает ещё не разобранные события и складывает открытый текст.
// Реплика без ключа пропускается и будет разобрана в следующий проход, когда ключ придёт.

import Foundation

public struct SearchHit: Sendable, Equatable, Identifiable {
    public let eventID: String
    public let roomID: String
    public let sender: String
    public let ts: Int
    public let text: String

    public var id: String { eventID }

    public init(eventID: String, roomID: String, sender: String, ts: Int, text: String) {
        self.eventID = eventID
        self.roomID = roomID
        self.sender = sender
        self.ts = ts
        self.text = text
    }
}

public enum Search {
    /// Свёртка для сравнения без учёта регистра; «ё» и «е» считаем одной буквой.
    public static func fold(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "ё", with: "е")
    }

    /// Что из реплики попадает в индекс: текст и событие, под которым его хранить (у правки — исходная реплика).
    static func entry(_ event: Event) -> (target: String, text: String)? {
        guard event.type == EventType.message, let id = event.eventID, !event.isRedacted else { return nil }
        let relation = event.content["m.relates_to"]
        if relation?["rel_type"]?.string == "m.replace", let target = relation?["event_id"]?.string {
            return (target, event.content["m.new_content"]?["body"]?.string ?? "")
        }
        return (id, event.content["body"]?.string ?? "")
    }

    /// Фоновый проход: разобрать неразобранные события, новые первыми. Возвращает, сколько реплик легло в индекс.
    /// `maxEvents` ограничивает один проход, чтобы не держать телефон занятым; остаток доберёт следующий.
    @discardableResult
    public static func index(store: Store, decrypt: @Sendable (Event, String) async -> Event?,
                             batch: Int = 200, maxEvents: Int = 2000) async throws -> Int {
        var cursor: Int?
        var seen = 0
        var added = 0
        while seen < maxEvents {
            let events = try await store.unindexedEvents(before: cursor, limit: batch)
            if events.isEmpty { break }
            seen += events.count
            cursor = events.compactMap(\.originServerTS).min() ?? 0
            for event in events {
                guard let id = event.eventID, let roomID = event.roomID else { continue }
                let clear: Event?
                if event.type == EventType.encrypted {
                    clear = event.isRedacted ? event : await decrypt(event, roomID)
                } else {
                    clear = event
                }
                // Ключа пока нет: в индекс не пишем, попробуем в другой раз.
                guard let clear else { continue }
                let ts = event.originServerTS ?? 0
                let sender = event.sender ?? ""
                if let (target, text) = entry(clear), !text.isEmpty {
                    try await store.indexSearch(eventID: target, roomID: roomID, sender: sender, ts: ts, text: text,
                                                folded: fold(text), replace: target != id)
                    added += 1
                    if target == id { continue }
                }
                // Разобрано, искать нечего (служебное, вложение без подписи, сама правка).
                try await store.indexSearch(eventID: id, roomID: roomID, sender: sender, ts: ts, text: "", folded: "")
            }
        }
        return added
    }

    /// Совпадения по запросу от двух знаков, новые первыми; `roomID` — искать только в одном чате.
    public static func find(_ query: String, in roomID: String? = nil, store: Store, limit: Int = 60) async throws -> [SearchHit] {
        let folded = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard folded.count >= 2 else { return [] }
        return try await store.searchText(folded: folded, roomID: roomID, limit: limit)
    }
}
