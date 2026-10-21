// Нютаг. Обращения разработчика: сервер отдаёт `announce.json` (`GET /_nyutag/v1/announce`), приложение показывает их
// каналом «Новости Нютага» в списке чатов. Формат общий с Android: `{id, from, until, repeat_days, title{ru,bxr,en},
// body{…}, actions[{type: url|donate, label{…}, url}], dismiss{…}}`. Язык выбирает интерфейс; если перевода нет,
// берётся русский, потом любой.

import Foundation

public struct Announcement: Sendable, Equatable, Identifiable {
    public struct Action: Sendable, Equatable {
        public enum Kind: Sendable, Equatable { case url(URL), donate }
        public let kind: Kind
        public let label: Translated

        public init(kind: Kind, label: Translated) {
            self.kind = kind
            self.label = label
        }
    }

    /// Текст на языках интерфейса: `ru`, `bxr`, `en`.
    public struct Translated: Sendable, Equatable {
        public let texts: [String: String]

        public init(_ texts: [String: String]) { self.texts = texts }

        public func text(_ lang: String) -> String {
            texts[lang] ?? texts["ru"] ?? texts.sorted { $0.key < $1.key }.first?.value ?? ""
        }

        static func read(_ json: JSONValue?) -> Translated? {
            if let one = json?.string { return Translated(["ru": one]) }
            guard let object = json?.object else { return nil }
            let texts = object.compactMapValues(\.string).filter { !$0.value.isEmpty }
            return texts.isEmpty ? nil : Translated(texts)
        }
    }

    public let id: String
    /// Показывать с этого дня (начало суток по времени устройства); `nil` — сразу.
    public let from: Date?
    /// Показывать до этого дня включительно; `nil` — бессрочно.
    public let until: Date?
    public let title: Translated
    public let body: Translated
    public let actions: [Action]

    public init(id: String, from: Date? = nil, until: Date? = nil, title: Translated, body: Translated, actions: [Action] = []) {
        self.id = id
        self.from = from
        self.until = until
        self.title = title
        self.body = body
        self.actions = actions
    }

    /// Объявление из записи сервера; без `id`, заголовка или текста — `nil`.
    public static func read(_ json: JSONValue) -> Announcement? {
        guard let id = json["id"]?.string, !id.isEmpty,
              let title = Translated.read(json["title"]), let body = Translated.read(json["body"]) else { return nil }
        let actions: [Action] = (json["actions"]?.array ?? []).compactMap { action in
            guard let label = Translated.read(action["label"]) else { return nil }
            switch action["type"]?.string {
            case "donate":
                return Action(kind: .donate, label: label)
            case "url":
                guard let url = action["url"]?.string.flatMap(URL.init), url.scheme == "https" else { return nil }
                return Action(kind: .url(url), label: label)
            default:
                return nil
            }
        }
        return Announcement(id: id, from: day(json["from"]), until: day(json["until"]).map { $0.addingTimeInterval(86400) },
                            title: title, body: body, actions: actions)
    }

    /// Все годные объявления списка сервера, свежие сверху (порядок файла — старые первыми).
    public static func read(all json: [JSONValue], now: Date = .now) -> [Announcement] {
        json.compactMap(read).filter { $0.isCurrent(at: now) }.reversed()
    }

    public func isCurrent(at now: Date) -> Bool {
        if let from, now < from { return false }
        if let until, now >= until { return false }
        return true
    }

    /// День `ГГГГ-ММ-ДД` как начало суток по часам устройства.
    static func day(_ json: JSONValue?) -> Date? {
        guard let text = json?.string else { return nil }
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

public extension NyutagService {
    /// Годные на сегодня объявления, свежие сверху.
    func currentAnnouncements(now: Date = .now) async throws(MatrixError) -> [Announcement] {
        Announcement.read(all: try await announcements(), now: now)
    }
}
