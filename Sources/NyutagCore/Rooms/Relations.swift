// Нютаг. Реплики, которые ссылаются на другие: правка своей реплики и реакция. Плюс кто сейчас набирает текст
// (`m.typing` в эфемерных событиях синхронизации) и кто в сети (`m.presence`).

import Foundation

public enum Relations {
    /// Правка своей текстовой реплики. Старые клиенты покажут `body` со звёздочкой, новые подставят `m.new_content`.
    public static func edit(of eventID: String, text: String) -> JSONValue {
        [
            "msgtype": "m.text", "body": .string("* " + text),
            "m.new_content": ["msgtype": "m.text", "body": .string(text)],
            "m.relates_to": ["rel_type": "m.replace", "event_id": .string(eventID)],
        ]
    }

    /// Реакция-аннотация на реплику.
    public static func reaction(to eventID: String, key: String) -> JSONValue {
        ["m.relates_to": ["rel_type": "m.annotation", "event_id": .string(eventID), "key": .string(key)]]
    }

    /// Кто набирает текст в комнате по последнему `m.typing`, кроме нас. `nil` — в этом ответе новостей нет.
    public static func typing(_ ephemeral: [Event], me: String) -> [String]? {
        guard let event = ephemeral.last(where: { $0.type == EventType.typing }) else { return nil }
        return (event.content["user_ids"]?.array ?? []).compactMap(\.string).filter { $0 != me }
    }

    /// Кто в сети: `online` — сейчас, иначе `lastActive` — когда был в последний раз (сервер даёт `last_active_ago`).
    public struct Presence: Sendable, Equatable {
        public let online: Bool
        public let lastActive: Date?

        public init(online: Bool, lastActive: Date?) {
            self.online = online
            self.lastActive = lastActive
        }
    }

    /// Статусы из `presence.events` ответа /sync: по пользователю последнее событие.
    public static func presence(_ events: [Event], now: Date = .now) -> [String: Presence] {
        var result: [String: Presence] = [:]
        for event in events where event.type == EventType.presence {
            guard let user = event.sender else { continue }
            let state = event.content["presence"]?.string ?? "offline"
            let online = state == "online" && (event.content["currently_active"]?.bool ?? true)
            let lastActive = event.content["last_active_ago"]?.int.map { now.addingTimeInterval(-Double($0) / 1000) }
            result[user] = Presence(online: online, lastActive: lastActive)
        }
        return result
    }
}
