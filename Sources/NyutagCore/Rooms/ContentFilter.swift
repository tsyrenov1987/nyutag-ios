// Нютаг. Фильтр недопустимого текста: мат, грубые оскорбления и национальные оскорбления по-русски и по-английски.
// Слово проверяется целиком, после приведения к нижнему регистру, ё → е, латинских двойников внутри кириллицы
// («xуй» → «хуй») и схлопывания повторов («бляяя» → «бля»). Корни подобраны так, чтобы не задевать обычные слова:
// «себе», «небо», «хлеб», «колебание», «страхуют», «команда», «мандарин», «хачапури», «жидкий», «бляха», «мудрый».

import Foundation

public enum ContentFilter {
    /// Знак, которым закрываем недопустимое слово; первая буква остаётся, чтобы было видно, что слово было.
    public static let maskCharacter: Character = "•"

    /// В тексте есть недопустимое слово.
    public static func contains(_ text: String) -> Bool {
        var found = false
        forEachWord(in: text) { word, _ in
            if isObjectionable(word) { found = true }
            return !found
        }
        return found
    }

    /// Текст с закрытыми недопустимыми словами; `nil` — закрывать нечего.
    public static func mask(_ text: String) -> String? {
        var ranges: [Range<String.Index>] = []
        forEachWord(in: text) { word, range in
            if isObjectionable(word) { ranges.append(range) }
            return true
        }
        guard !ranges.isEmpty else { return nil }
        var out = text
        for range in ranges.reversed() {
            let word = text[range]
            let hidden = String(word.prefix(1)) + String(repeating: maskCharacter, count: max(word.count - 1, 1))
            out.replaceSubrange(range, with: hidden)
        }
        return out
    }

    /// Одно слово недопустимо.
    public static func isObjectionable(_ word: some StringProtocol) -> Bool {
        let plain = normalize(word)
        guard !plain.isEmpty, !allowed.contains(where: plain.hasPrefix) else { return false }
        if matches(plain) { return true }
        // Повторы схлопываем только в кириллице: в английском двойные буквы законны («shiitake»).
        guard isCyrillic(plain) else { return false }
        let squeezed = squeeze(plain)
        return squeezed != plain && matches(squeezed)
    }

    // MARK: - Правила

    /// Слово целиком.
    static let exact: Set<String> = [
        "бля", "еб", "сука", "суки", "суке", "суку", "сукой", "сукам", "суками",
        "сучка", "сучки", "сучке", "сучку", "сучкой", "сучара", "сучары",
        "педик", "педики", "педика", "педику", "педиком", "педиков", "педикам", "педиками",
        "манда", "манды", "манде", "манду", "мандой",
        "чмо", "хач", "хачи", "хача", "хачу", "хачей", "хачам", "хачами", "хачье",
        "жид", "жида", "жиду", "жидом", "жиды", "жидов", "жидам", "жидами", "жидовка", "жидовки", "жидяра",
        "чурка", "чурки", "чурке", "чурку", "чуркой", "чурок", "чуркам", "чурками",
        "fag", "fags", "twat", "wanker", "suka", "huy", "huj",
    ]

    /// Корень где угодно в слове: обычных слов с такими сочетаниями нет.
    static let anywhere: [String] = [
        "пизд", "бляд", "пидор", "пидар", "пидр", "шлюх", "залуп", "гандон", "гондон", "мандавош",
        "долбоеб", "долбаеб", "говн", "дерьм", "жоп", "ниггер", "нигга",
        "fuck", "bullshit", "horseshit", "pizd", "blyat", "blyad", "bljat", "bljad", "nahuy", "nahuj",
    ]

    /// Слово начинается так.
    static let starts: [String] = [
        "блят", "мудак", "мудач", "мудил", "мудень", "мудозвон", "мудох", "херн", "чмош",
        "shit", "cunt", "bitch", "nigger", "nigga", "faggot", "whore", "slut", "asshole", "dickhead", "motherf",
    ]

    /// Начала, которые не трогаем, хотя они похожи на корень: «Ебург» — Екатеринбург, «сукка» — праздничный шалаш.
    static let allowed: [String] = ["ебург", "сукк"]

    /// Глагольные приставки перед корнем: «на-хуй», «за-ебал», «отъ-ебись». Без «с» и «не»: «себе», «небо».
    static let prefixes: [String] = [
        "", "на", "по", "о", "ни", "за", "до", "от", "при", "вы", "раз", "рас", "под", "об", "у", "из",
        "про", "пере", "недо", "съ", "въ", "отъ", "разъ", "подъ", "объ", "изъ",
    ]

    /// Корни, которые ищем в начале слова, в том числе после приставки.
    static let roots: [String] = [
        "хуй", "хуя", "хую", "хуе", "хуи",
        "еба", "ебу", "ебл", "ебн", "ебе", "еби", "ебо", "ебы", "ебт", "ебуч",
    ]

    /// Корни только после приставки: «нахер», «похер», «охереть», но «Херсон» и «херес» — нет.
    static let prefixedOnly: [String] = ["хер"]

    static func matches(_ word: String) -> Bool {
        if exact.contains(word) { return true }
        if anywhere.contains(where: word.contains) { return true }
        if starts.contains(where: word.hasPrefix) { return true }
        for prefix in prefixes where word.hasPrefix(prefix) {
            let rest = word.dropFirst(prefix.count)
            if rest == "еб" { return true }
            if roots.contains(where: rest.hasPrefix) { return true }
            if !prefix.isEmpty, prefixedOnly.contains(where: rest.hasPrefix) { return true }
        }
        return false
    }

    // MARK: - Приведение

    /// Латинские и цифровые двойники кириллических букв; применяем только к слову, где есть кириллица.
    static let lookalikes: [Character: Character] = [
        "a": "а", "c": "с", "e": "е", "o": "о", "p": "р", "x": "х", "y": "у", "k": "к", "m": "м",
        "t": "т", "h": "н", "u": "и", "b": "в", "3": "з", "0": "о", "6": "б", "@": "а",
    ]

    /// Бурятские и прочие варианты букв, которые подставляет клавиатура или «Бурятские буквы» при наборе.
    static let variants: [Character: Character] = ["ё": "е", "ү": "у", "ө": "о"]

    static func normalize(_ word: some StringProtocol) -> String {
        let lower = word.lowercased()
        let cyrillic = isCyrillic(lower)
        return String(lower.map { char in
            if let variant = variants[char] { return variant }
            if cyrillic, let twin = lookalikes[char] { return twin }
            return char
        })
    }

    static func isCyrillic(_ word: some StringProtocol) -> Bool {
        word.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
    }

    /// Повторы одной буквы — в одну: «сууука» → «сука».
    static func squeeze(_ word: String) -> String {
        var out = ""
        for char in word where char != out.last { out.append(char) }
        return out
    }

    /// Слова текста: буквы, цифры и «@» подряд. `body` возвращает `false`, чтобы остановиться.
    static func forEachWord(in text: String, _ body: (Substring, Range<String.Index>) -> Bool) {
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            let inWord = char.isLetter || char.isNumber || char == "@"
            if inWord, start == nil { start = index }
            if !inWord, let from = start {
                if !body(text[from..<index], from..<index) { return }
                start = nil
            }
            index = text.index(after: index)
        }
        if let from = start { _ = body(text[from...], from..<text.endIndex) }
    }
}
