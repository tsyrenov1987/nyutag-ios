// Нютаг. Обращения разработчика: разбор записей сервера, языки, сроки, порядок.

import Foundation
import Testing
@testable import NyutagCore

@Suite struct AnnouncementsTests {
    let sample: JSONValue = [
        "id": "2026-10-support",
        "from": "2026-10-15",
        "until": "2026-12-31",
        "repeat_days": 14,
        "title": ["ru": "Поддержите Нютаг", "bxr": "Нютагта туһалагты", "en": "Support Nyutag"],
        "body": ["ru": "Нютаг делает маленькая студия.", "en": "Nyutag is made by a small studio."],
        "actions": [
            ["type": "url", "label": ["ru": "Поддержать", "en": "Support"], "url": "https://nyutag.chat/"],
            ["type": "donate", "label": ["ru": "Чай разработчику"]],
            ["type": "url", "label": ["ru": "Плохая"], "url": "http://nyutag.chat/"],
            ["type": "video", "label": ["ru": "Неизвестная"]],
        ],
        "dismiss": ["ru": "Позже"],
    ]

    @Test("запись читается: языки с запасным русским, только https-ссылки и донат")
    func read() throws {
        let one = try #require(Announcement.read(sample))
        #expect(one.id == "2026-10-support")
        #expect(one.title.text("bxr") == "Нютагта туһалагты")
        #expect(one.body.text("bxr") == "Нютаг делает маленькая студия.")
        #expect(one.body.text("en") == "Nyutag is made by a small studio.")
        #expect(one.actions.count == 2)
        #expect(one.actions[0].kind == .url(URL(string: "https://nyutag.chat/")!))
        #expect(one.actions[0].label.text("bxr") == "Поддержать")
        #expect(one.actions[1].kind == .donate)
        #expect(Announcement.read(["id": "x", "title": ["ru": "Без текста"]]) == nil)
        #expect(Announcement.read(["title": ["ru": "Без id"], "body": ["ru": "…"]]) == nil)
        let plain = try #require(Announcement.read(["id": "p", "title": "Строкой", "body": "Тоже строкой"]))
        #expect(plain.title.text("en") == "Строкой")
    }

    @Test("сроки: до начала — рано, последний день — ещё годно, после — нет; свежие сверху")
    func currentAndOrder() throws {
        let one = try #require(Announcement.read(sample))
        let day = { (text: String) in Announcement.day(.string(text))! }
        #expect(!one.isCurrent(at: day("2026-10-14").addingTimeInterval(3600)))
        #expect(one.isCurrent(at: day("2026-10-15")))
        #expect(one.isCurrent(at: day("2026-12-31").addingTimeInterval(23 * 3600)))
        #expect(!one.isCurrent(at: day("2027-01-01")))

        let old: JSONValue = ["id": "old", "title": "Старое", "body": "…", "until": "2026-10-01"]
        let open: JSONValue = ["id": "open", "title": "Бессрочное", "body": "…"]
        let list = Announcement.read(all: [old, sample, open, ["id": "", "title": "x", "body": "y"]], now: day("2026-11-01"))
        #expect(list.map(\.id) == ["open", "2026-10-support"])
    }
}
