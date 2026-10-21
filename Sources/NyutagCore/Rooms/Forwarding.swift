// Нютаг. Пересылка: из уже расшифрованной реплики собираем новую — без ответа, правок и цитаты-подстановки
// старых клиентов, с пометкой «переслано». Вложение уходит той же ссылкой и тем же ключом, заново не грузится.
// Одноразовое фото, опросы и звонки не пересылаются.

import Foundation

public enum Forwarding {
    public static let forwardedKey = "chat.nyutag.forwarded"

    static let msgtypes: Set<String> = ["m.text", "m.notice", "m.emote", "m.image", "m.file", "m.video", "m.audio", "m.location"]

    /// Тип и содержимое новой реплики. `replaced` — `m.new_content` последней правки, если она была. `nil` — нельзя.
    public static func content(of event: Event, replaced: JSONValue? = nil) -> (type: String, content: JSONValue)? {
        guard !event.isRedacted, event.type == EventType.message || event.type == EventType.sticker,
              var content = (replaced ?? event.content).object else { return nil }
        if event.type == EventType.message {
            guard let msgtype = content["msgtype"]?.string, msgtypes.contains(msgtype) else { return nil }
        }
        guard content[Attachment.viewOnceKey]?.bool != true else { return nil }
        let wasReply = event.content["m.relates_to"]?["m.in_reply_to"] != nil
        content["m.relates_to"] = nil
        content["m.new_content"] = nil
        if wasReply, replaced == nil {
            if let body = content["body"]?.string { content["body"] = .string(stripReplyFallback(body)) }
            content["format"] = nil
            content["formatted_body"] = nil
        }
        content[forwardedKey] = true
        return (event.type, .object(content))
    }

    /// Старые клиенты кладут цитату в начало текста: строки «> …» и пустая строка после них.
    static func stripReplyFallback(_ body: String) -> String {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.hasPrefix("> ") == true else { return body }
        var rest = lines.drop { $0.hasPrefix(">") }
        if rest.first?.isEmpty == true { rest = rest.dropFirst() }
        return rest.isEmpty ? body : rest.joined(separator: "\n")
    }
}
