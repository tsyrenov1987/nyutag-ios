// Нютаг. Пересылка: что уходит в новый чат и что не пересылается.

import Foundation
import Testing
@testable import NyutagCore

@Suite struct ForwardingTests {
    func event(_ content: JSONValue, redacted: Bool = false) -> Event { event(type: EventType.message, content, redacted: redacted) }

    func event(type: String, _ content: JSONValue, redacted: Bool = false) -> Event {
        Event(eventID: "$e", type: type, sender: "@a:x", originServerTS: 1, content: content,
              unsigned: redacted ? ["redacted_because": [:]] : nil, roomID: "!r:x")
    }

    @Test("текст: без ответа и цитаты-подстановки, с пометкой")
    func text() throws {
        let source = event(["msgtype": "m.text", "body": "> <@b:x> привет\n> как дела\n\nвсё хорошо",
                            "format": "org.matrix.custom.html", "formatted_body": "<mx-reply>…</mx-reply>всё хорошо",
                            "m.relates_to": ["m.in_reply_to": ["event_id": "$q"]]])
        let out = try #require(Forwarding.content(of: source))
        #expect(out.type == EventType.message)
        #expect(out.content == ["msgtype": "m.text", "body": "всё хорошо", Forwarding.forwardedKey: true])
    }

    @Test("правка: уходит последний текст")
    func edited() throws {
        let source = event(["msgtype": "m.text", "body": "опечатка"])
        let out = try #require(Forwarding.content(of: source, replaced: ["msgtype": "m.text", "body": "без опечатки"]))
        #expect(out.content["body"]?.string == "без опечатки")
    }

    @Test("вложение и стикер — той же ссылкой и тем же ключом")
    func media() throws {
        let file: JSONValue = ["url": "mxc://x/1", "key": ["k": "секрет"], "iv": "iv", "hashes": ["sha256": "h"], "v": "v2"]
        let photo = try #require(Forwarding.content(of: event(["msgtype": "m.image", "body": "фото.jpg", "file": file])))
        #expect(photo.content["file"] == file)
        let sticker = try #require(Forwarding.content(of: event(type: EventType.sticker, ["body": "Сайн байна!", "url": "mxc://x/2", "info": [:]])))
        #expect(sticker.type == EventType.sticker)
        #expect(sticker.content["url"]?.string == "mxc://x/2")
    }

    @Test("не пересылаются: одноразовое фото, удалённое, опрос, служебное")
    func refused() {
        #expect(Forwarding.content(of: event(["msgtype": "m.image", "body": "x", "url": "mxc://x/1", Attachment.viewOnceKey: true])) == nil)
        #expect(Forwarding.content(of: event(["msgtype": "m.text", "body": "x"], redacted: true)) == nil)
        #expect(Forwarding.content(of: event(type: "m.poll.start", ["body": "?"])) == nil)
        #expect(Forwarding.content(of: event(["msgtype": "m.key.verification.request", "body": "x"])) == nil)
    }

    @Test("цитата без пустой строки и текст с «>» внутри не ломаются")
    func fallback() {
        #expect(Forwarding.stripReplyFallback("> a\nb") == "b")
        #expect(Forwarding.stripReplyFallback("a\n> b") == "a\n> b")
        #expect(Forwarding.stripReplyFallback("> только цитата") == "> только цитата")
    }
}
