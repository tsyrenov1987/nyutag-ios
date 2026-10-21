// Нютаг. Реплики, которые ссылаются на другие: правка своей реплики и реакция. Плюс кто сейчас набирает текст
// (`m.typing` в эфемерных событиях синхронизации).

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
}
