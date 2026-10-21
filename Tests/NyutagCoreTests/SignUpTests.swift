// Ник нового участника из имени: латиница из кириллицы и бурятских букв, допустимые знаки, запасные варианты.

import Testing
@testable import NyutagCore

@Suite("Ник при регистрации")
struct SignUpTests {
    @Test("имя на русском и бурятском превращается в латинский ник")
    func transliteration() {
        #expect(Nickname.from(name: "Арюна Доржиева") == "aryuna.dorzhieva")
        #expect(Nickname.from(name: "Баярма Һэрэн-Дулма") == "bayarma.heren-dulma")
        #expect(Nickname.from(name: "Түмэн Өлзы") == "tumen.olzy")
        #expect(Nickname.from(name: "Чингис") == "chingis")
        #expect(Nickname.from(name: "Ivan Petrov") == "ivan.petrov")
    }

    @Test("лишние знаки уходят, разделители не повторяются и не стоят по краям")
    func tidy() {
        #expect(Nickname.from(name: "  Аня  ✨  ") == "anya")
        #expect(Nickname.from(name: "Ъ") == "")
        #expect(Nickname.from(name: "Мэргэн..__Б") == "mergen.b")
        #expect(Nickname.clean("@Saryuna_99!") == "saryuna_99")
        #expect(Nickname.from(name: String(repeating: "Сэсэг ", count: 10)).count <= Nickname.longest)
    }

    @Test("проверка ника и запасные варианты с цифрами")
    func validity() {
        #expect(Nickname.isValid("ab"))
        #expect(!Nickname.isValid("a"))
        #expect(!Nickname.isValid("Ab"))
        #expect(!Nickname.isValid("арюна"))
        let more = Nickname.alternatives(for: "aryuna")
        #expect(more.count == 4)
        #expect(Set(more).count == 4)
        #expect(more.allSatisfy { $0.hasPrefix("aryuna") && Nickname.isValid($0) && $0 != "aryuna" })
    }
}
