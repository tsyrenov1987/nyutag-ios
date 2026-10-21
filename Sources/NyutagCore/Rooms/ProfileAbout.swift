// Нютаг. «О себе» в профиле: пара слов, тоонто нютаг, уг гарбал и год по восточному календарю. Поля профиля
// MSC4133 (`NyutagProfileKey`), значения — строки; год на проводе `<стихия>-<животное>`, например `fire-horse`.

import Foundation

/// Год 60-летнего цикла. Стихия меняется раз в два года, животное — каждый год; 1984 — деревянная крыса.
public struct EastYear: Sendable, Equatable, Hashable {
    public static let elements = ["wood", "fire", "earth", "metal", "water"]
    public static let animals = ["rat", "ox", "tiger", "rabbit", "dragon", "snake",
                                 "horse", "sheep", "monkey", "rooster", "dog", "pig"]

    /// Номера в `elements` и `animals`.
    public let element: Int
    public let animal: Int

    public init(year: Int) {
        let shift = ((year - 1984) % 60 + 60) % 60
        element = shift % 10 / 2
        animal = shift % 12
    }

    public init?(key: String) {
        let parts = key.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count == 2, let element = Self.elements.firstIndex(of: parts[0]),
              let animal = Self.animals.firstIndex(of: parts[1]) else { return nil }
        self.element = element
        self.animal = animal
    }

    public var key: String { "\(Self.elements[element])-\(Self.animals[animal])" }
}

public struct ProfileAbout: Sendable, Equatable {
    public static let maxAbout = 500
    public static let maxShort = 100

    public var about: String
    public var toonto: String
    public var ug: String
    /// Ключ `EastYear`, пусто — не указан.
    public var eastYear: String

    public init(about: String = "", toonto: String = "", ug: String = "", eastYear: String = "") {
        self.about = about
        self.toonto = toonto
        self.ug = ug
        self.eastYear = eastYear
    }

    public init(profile: Profile) {
        self.init(about: profile[.about] ?? "", toonto: profile[.toonto] ?? "", ug: profile[.ug] ?? "",
                  eastYear: profile[.eastYear] ?? "")
    }

    public var isEmpty: Bool { self == ProfileAbout() }

    /// Без пробелов по краям, в пределах длины; незнакомый год отбрасываем.
    public var cleaned: ProfileAbout {
        func trim(_ text: String, _ limit: Int) -> String {
            String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
        }
        return ProfileAbout(about: trim(about, Self.maxAbout), toonto: trim(toonto, Self.maxShort),
                            ug: trim(ug, Self.maxShort), eastYear: EastYear(key: eastYear)?.key ?? "")
    }

    /// Что отправить на сервер: только изменившиеся поля, пустое — удалить.
    public func edits(from old: ProfileAbout) -> [NyutagProfileKey: String?] {
        let fresh = cleaned
        var edits: [NyutagProfileKey: String?] = [:]
        for (key, path) in [(NyutagProfileKey.about, \ProfileAbout.about), (.toonto, \.toonto), (.ug, \.ug), (.eastYear, \.eastYear)]
        where fresh[keyPath: path] != old[keyPath: path] {
            edits[key] = fresh[keyPath: path].isEmpty ? .some(nil) : fresh[keyPath: path]
        }
        return edits
    }
}
