// Нютаг. Отложенные сообщения, как в Telegram. Сервер Matrix отложенную отправку не умеет, поэтому очередь
// живёт на телефоне, а отправляет её приложение, когда срок наступил и оно открыто. Номер транзакции выводится
// из номера сообщения: если приложение упало между отправкой и снятием с очереди, повтор сервер не задвоит.

import Foundation

public struct ScheduledMessage: Sendable, Equatable, Identifiable {
    public let id: String
    /// Чья очередь: на телефоне может побывать не одна учётка.
    public let account: String
    public let roomID: String
    public let body: String
    /// Когда отправить, мс.
    public var sendAt: Int

    public init(id: String = UUID().uuidString.lowercased(), account: String, roomID: String, body: String, sendAt: Date) {
        self.id = id
        self.account = account
        self.roomID = roomID
        self.body = body
        self.sendAt = Int(sendAt.timeIntervalSince1970 * 1000)
    }

    init?(json: JSONValue) {
        guard let id = json["id"]?.string, let account = json["account"]?.string, let roomID = json["room"]?.string,
              let body = json["body"]?.string, let sendAt = json["at"]?.int else { return nil }
        self.id = id
        self.account = account
        self.roomID = roomID
        self.body = body
        self.sendAt = sendAt
    }

    var json: JSONValue {
        ["id": .string(id), "account": .string(account), "room": .string(roomID), "body": .string(body), "at": .int(sendAt)]
    }

    public var date: Date { Date(timeIntervalSince1970: TimeInterval(sendAt) / 1000) }
    public var transactionID: String { "scheduled-\(id)" }
}

public struct ScheduledQueue: Sendable, Equatable {
    /// Ближайшие первыми.
    public private(set) var messages: [ScheduledMessage]

    public init(_ messages: [ScheduledMessage] = []) {
        var seen: Set<String> = []
        self.messages = messages.filter { seen.insert($0.id).inserted }.sorted { ($0.sendAt, $0.id) < ($1.sendAt, $1.id) }
    }

    /// Битые записи пропускаем: очередь не должна теряться целиком из-за одной.
    public init(data: Data?) {
        let items = data.flatMap { try? JSONValue(data: $0) }?.array ?? []
        self.init(items.compactMap(ScheduledMessage.init(json:)))
    }

    public var data: Data { (try? JSONValue.array(messages.map(\.json)).data()) ?? Data("[]".utf8) }

    public func inRoom(_ roomID: String, account: String) -> [ScheduledMessage] {
        messages.filter { $0.account == account && $0.roomID == roomID }
    }

    public func due(account: String, now: Date = Date()) -> [ScheduledMessage] {
        let ms = Int(now.timeIntervalSince1970 * 1000)
        return messages.filter { $0.account == account && $0.sendAt <= ms }
    }

    /// Когда наступит ближайший срок этой учётки.
    public func nextDue(account: String) -> Date? {
        messages.first { $0.account == account }?.date
    }

    public func adding(_ message: ScheduledMessage) -> ScheduledQueue {
        ScheduledQueue(messages.filter { $0.id != message.id } + [message])
    }

    public func removing(_ id: String) -> ScheduledQueue {
        ScheduledQueue(messages.filter { $0.id != id })
    }

    /// «Отправить сейчас»: срок переносится на этот момент, отправит обычный обход.
    public func sendingNow(_ id: String, now: Date = Date()) -> ScheduledQueue {
        let ms = Int(now.timeIntervalSince1970 * 1000)
        return ScheduledQueue(messages.map { message in
            guard message.id == id else { return message }
            var copy = message
            copy.sendAt = min(copy.sendAt, ms)
            return copy
        })
    }

    /// Учётка вышла — её очередь больше некому отправить.
    public func removingAccount(_ account: String) -> ScheduledQueue {
        ScheduledQueue(messages.filter { $0.account != account })
    }
}
