// Нютаг. Адрес нового участника: из имени, как его набрал человек, получаем латинский ник для Matrix ID.
// Кириллицу, включая бурятские ө, ү, һ, пишем латиницей; занятость проверяет сервер.

import Foundation

public enum Nickname {
    /// Разрешённые в нике знаки; сервис регистрации принимает 2–32 таких знака.
    static let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789._-")
    static let longest = 24

    static let latin: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "yo", "ж": "zh", "з": "z", "и": "i",
        "й": "y", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t",
        "у": "u", "ф": "f", "х": "kh", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "sch", "ъ": "", "ы": "y", "ь": "",
        "э": "e", "ю": "yu", "я": "ya", "ө": "o", "ү": "u", "һ": "h",
    ]

    /// Ник из имени: «Арюна Доржиева» → `aryuna.dorzhieva`. Пусто, если из имени ничего не вышло.
    public static func from(name: String) -> String {
        var out = ""
        for char in name.lowercased() {
            if let spelled = latin[char] {
                out += spelled
            } else if allowed.contains(char) {
                out.append(char)
            } else if char.isWhitespace || char == "," {
                out.append(".")
            }
        }
        return tidy(out)
    }

    /// То, что человек набрал в поле ника сам: те же правила, без смены регистра в середине.
    public static func clean(_ typed: String) -> String {
        tidy(String(typed.lowercased().filter { allowed.contains($0) }))
    }

    public static func isValid(_ nick: String) -> Bool {
        (2...32).contains(nick.count) && nick.allSatisfy { allowed.contains($0) }
    }

    /// Запасные варианты, если ник занят: с двумя-тремя цифрами в конце.
    public static func alternatives(for nick: String, count: Int = 4) -> [String] {
        var seen: Set<String> = [nick]
        var result: [String] = []
        while result.count < count {
            let candidate = String(nick.prefix(longest - 4)) + String(Int.random(in: 10...999))
            if seen.insert(candidate).inserted { result.append(candidate) }
        }
        return result
    }

    private static func tidy(_ raw: String) -> String {
        var out = ""
        for char in raw {
            // Подряд идущие разделители схлопываем в один.
            if ".-_".contains(char), let last = out.last, ".-_".contains(last) { continue }
            out.append(char)
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        return String(trimmed.prefix(longest)).trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
    }
}

public extension MatrixClient {
    /// Свободен ли ник для регистрации. Занятый сервер отдаёт как `M_USER_IN_USE`, недопустимый — `M_INVALID_USERNAME`.
    func isUsernameAvailable(_ nick: String) async throws(MatrixError) -> Bool {
        do {
            let json: JSONValue = try await request(.get, "register/available", query: ["username": nick],
                                                    authenticated: false)
            return json["available"]?.bool == true
        } catch where error.errcode == "M_USER_IN_USE" || error.errcode == "M_INVALID_USERNAME" {
            return false
        }
    }
}
