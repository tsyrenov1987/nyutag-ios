// Нютаг. Бурятские буквы ө, ү, һ при наборе. На русской раскладке их нет, и в переписке их заменяют латиницей:
// «hайн», «yнэр», «θглөө». Такую замену возвращаем к бурятской букве, но только внутри кириллического слова:
// английский текст, ссылки и ники остаются как есть.

import Foundation

public enum BuryatLetters {
    /// Буквы для строки над полем ввода, в порядке алфавита.
    public static let row: [Character] = ["ө", "ү", "һ"]

    static let substitutes: [Character: Character] = [
        "h": "һ", "H": "Һ",
        "y": "ү", "Y": "Ү",
        "θ": "ө", "Θ": "Ө", "ɵ": "ө", "Ɵ": "Ө",
    ]

    static func isCyrillic(_ char: Character) -> Bool {
        char.unicodeScalars.allSatisfy { (0x0400...0x04FF).contains($0.value) } && char.isLetter
    }

    /// Текст с заменёнными заменителями; число знаков не меняется, поэтому курсор остаётся на месте.
    /// `nil` — менять нечего.
    public static func fix(_ text: String) -> String? {
        let chars = Array(text)
        var out = chars
        var changed = false
        for index in chars.indices {
            guard let letter = substitutes[chars[index]] else { continue }
            // Соседи смотрим по исходному тексту: «hh» в латинице так и останется латиницей.
            let before = index > 0 ? chars[index - 1] : nil
            let after = index + 1 < chars.count ? chars[index + 1] : nil
            guard before.map(isCyrillic) == true || after.map(isCyrillic) == true else { continue }
            out[index] = letter
            changed = true
        }
        return changed ? String(out) : nil
    }

    /// Буква из строки над полем: заглавная в начале текста и после конца предложения.
    public static func letter(_ letter: Character, after prefix: Substring) -> Character {
        let trimmed = prefix.reversed().drop(while: { $0 == " " || $0 == "\n" })
        let capital = trimmed.first.map { ".!?".contains($0) } ?? true
        return capital ? Character(String(letter).uppercased()) : letter
    }
}
