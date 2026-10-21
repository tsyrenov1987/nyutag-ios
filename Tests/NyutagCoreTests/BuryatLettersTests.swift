// Нютаг. Бурятские буквы при наборе: латинские заменители внутри кириллицы становятся ө/ү/һ, латиница не трогается.

import Testing
@testable import NyutagCore

@Suite struct BuryatLettersTests {
    @Test("заменители внутри кириллического слова")
    func replaces() {
        #expect(BuryatLetters.fix("hайн байна") == "һайн байна")
        #expect(BuryatLetters.fix("Hайн") == "Һайн")
        #expect(BuryatLetters.fix("yнэр") == "үнэр")
        #expect(BuryatLetters.fix("θглөө") == "өглөө")
        #expect(BuryatLetters.fix("ɵдэр") == "өдэр")
        #expect(BuryatLetters.fix("мэдэhэн") == "мэдэһэн")
    }

    @Test("латиница, ссылки и уже верный текст не меняются")
    func keepsLatin() {
        #expect(BuryatLetters.fix("hello, how are you") == nil)
        #expect(BuryatLetters.fix("https://nyutag.chat/h") == nil)
        #expect(BuryatLetters.fix("сайн байна") == nil)
        #expect(BuryatLetters.fix("hey привет") == nil)
        #expect(BuryatLetters.fix("") == nil)
    }

    @Test("длина в знаках сохраняется")
    func sameLength() {
        let text = "hайн yнэр θглөө"
        #expect(BuryatLetters.fix(text)?.count == text.count)
    }

    @Test("заглавная в начале и после точки")
    func capital() {
        #expect(BuryatLetters.letter("һ", after: "") == "Һ")
        #expect(BuryatLetters.letter("ө", after: "Сайн. ") == "Ө")
        #expect(BuryatLetters.letter("ү", after: "сайн ") == "ү")
        #expect(BuryatLetters.letter("һ", after: "ой!\n") == "Һ")
    }
}
