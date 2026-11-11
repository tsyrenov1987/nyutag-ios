// Нютаг. Фильтр недопустимого текста: ловит мат и оскорбления, не задевает обычные слова.

import Testing
@testable import NyutagCore

@Suite struct ContentFilterTests {
    @Test("мат и оскорбления ловятся", arguments: [
        "хуй", "Нахуй", "похуй", "охуеть", "нихуя", "хуёво", "пизда", "распиздяй", "блядь", "бля", "блять",
        "ебать", "заебал", "отъебись", "выебать", "уебок", "ёбаный", "долбоёб", "ебло", "наебнулся", "еб",
        "сука", "сучка", "мудак", "мудило", "пидор", "пидорас", "педик", "шлюха", "залупа", "гондон",
        "говно", "дерьмо", "жопа", "чмо", "нахер", "похер", "херня", "жид", "хачи", "ниггер",
        "fuck", "Motherfucker", "shit", "bullshit", "bitch", "cunt", "nigger", "faggot", "whore",
    ])
    func catches(_ word: String) {
        #expect(ContentFilter.isObjectionable(word), "\(word)")
    }

    @Test("обычные слова не задеваются", arguments: [
        "себе", "небо", "небесный", "хлеб", "хлеба", "вебинар", "ребёнок", "колебание", "учебник", "погребение",
        "лебедь", "требовать", "Глеб", "дебаты", "страхуют", "застрахуешь", "застрахуй", "худой", "художник",
        "хутор", "хурма", "хуже", "Хуан", "команда", "мандарин", "мандат", "хачапури", "жидкий", "жидкость",
        "бляха", "бляшка", "мудрый", "премудрость", "педиатр", "педикюр", "сукно", "сучок", "херес", "Херсон",
        "Ебург", "сукка", "шлюз", "Нигер", "hello", "Scunthorpe", "rebate", "shiitake", "Dick",
        "сайн байна", "һайн", "үнэр",
    ])
    func spares(_ word: String) {
        #expect(!ContentFilter.isObjectionable(word), "\(word)")
        #expect(ContentFilter.mask(word) == nil, "\(word)")
    }

    @Test("латинские двойники, цифры и растянутые буквы внутри кириллицы")
    func disguises() {
        #expect(ContentFilter.isObjectionable("xуй"))
        #expect(ContentFilter.isObjectionable("6ля"))
        #expect(ContentFilter.isObjectionable("бляяяя"))
        #expect(ContentFilter.isObjectionable("сууука"))
        #expect(ContentFilter.isObjectionable("БЛЯТЬ"))
        #expect(ContentFilter.isObjectionable("хүй"))
    }

    @Test("в тексте закрыто только недопустимое слово, первая буква и длина на месте")
    func masks() {
        #expect(ContentFilter.mask("ну ты и мудак, честно") == "ну ты и м••••, честно")
        #expect(ContentFilter.mask("Блять, опять дождь") == "Б••••, опять дождь")
        #expect(ContentFilter.mask("привет, как дела?") == nil)
        #expect(ContentFilter.mask("fuck this shit") == "f••• this s•••")
        #expect(ContentFilter.contains("иди нахуй"))
        #expect(!ContentFilter.contains("иди на хутор"))
        #expect(!ContentFilter.contains(""))
    }

    @Test("реплика в ленте: текст и цитата закрыты, остальное на месте")
    func feedItem() {
        let quote = FeedItem.Quote(eventID: "$0", senderName: "Б", preview: .text("сука"))
        let item = FeedItem(id: "$1", sender: "@a:x", senderName: "А", isMine: false, ts: 5, body: .text("ты мудак"),
                            edited: false, reply: quote, reactions: [], attachment: nil, isRead: false)
        let shown = item.filtered()
        #expect(shown?.body == .text("ты м••••"))
        #expect(shown?.reply?.preview == .text("с•••"))
        #expect(shown?.id == "$1" && shown?.ts == 5 && shown?.sender == "@a:x")
        let clean = FeedItem(id: "$2", sender: "@a:x", senderName: "А", isMine: false, ts: 6, body: .text("привет"),
                             edited: false, reply: nil, reactions: [], attachment: nil, isRead: false)
        #expect(clean.filtered() == nil)
    }
}
