// Нютаг. Лунный календарь: даты Сагаалгана и день по зурхаю. Даты Сагаалгана — таблица по системе Пхугпа
// из нашего же приложения «Зурхай»; дни зурхая — его же данные, сжатые в `App/Calendar/zurkhai-days.json`.

import Foundation

/// Календарный день без часового пояса: сравниваем и считаем по компонентам, а не по моментам времени.
public struct Day: Sendable, Equatable, Comparable, Hashable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init(_ date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    /// Номер дня от 1970-01-01, чтобы считать разницу без часовых поясов.
    var ordinal: Int {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: "UTC")!
        let date = gregorian.date(from: DateComponents(year: year, month: month, day: day)) ?? .distantPast
        return Int((date.timeIntervalSince1970 / 86_400).rounded(.down))
    }

    public func days(to other: Day) -> Int { other.ordinal - ordinal }

    public static func < (lhs: Day, rhs: Day) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

public enum Sagaalgan {
    /// Первый день Белого месяца по годам.
    static let dates: [Int: (month: Int, day: Int)] = [
        2024: (2, 10), 2025: (2, 28), 2026: (2, 18), 2027: (2, 7), 2028: (2, 26), 2029: (2, 14),
        2030: (3, 5), 2031: (2, 22), 2032: (2, 12), 2033: (3, 1), 2034: (2, 19), 2035: (2, 8),
    ]

    public static var years: ClosedRange<Int> { 2024...2035 }

    public static func day(in year: Int) -> Day? {
        dates[year].map { Day(year: year, month: $0.month, day: $0.day) }
    }

    /// Ближайший Сагаалган, начиная с сегодняшнего дня (сегодня — 0 дней). `nil` за пределами таблицы.
    public static func next(from today: Day) -> (day: Day, daysLeft: Int)? {
        for year in today.year...(today.year + 1) {
            if let day = day(in: year), day >= today { return (day, today.days(to: day)) }
        }
        return nil
    }

    /// Все даты от года `from` до конца таблицы.
    public static func upcoming(from year: Int) -> [Day] {
        years.filter { $0 >= year }.compactMap(day(in:))
    }
}

/// День по зурхаю: лунные сутки, стрижка и советы.
public struct ZurkhaiDay: Sendable, Equatable {
    public let lunarDay: Int
    public let haircutGood: Bool
    public let haircut: String
    public let favorable: String
    public let unfavorable: String
}

/// Сжатые дни: строки один раз в таблице, у дня — номера строк. Дни идут подряд от `from`.
public struct ZurkhaiDays: Sendable {
    struct Table: Decodable {
        let strings: [String]
        let days: [[Int]]
    }

    struct File: Decodable {
        let from: String
        let ru: Table
        let en: Table
    }

    let start: Day
    let ru: Table
    let en: Table

    public init(data: Data) throws {
        let file = try JSONDecoder().decode(File.self, from: data)
        let parts = file.from.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "from")) }
        start = Day(year: parts[0], month: parts[1], day: parts[2])
        ru = file.ru
        en = file.en
    }

    /// Последний день, на который есть данные.
    public var last: Day? {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: "UTC")!
        guard let first = gregorian.date(from: DateComponents(year: start.year, month: start.month, day: start.day)),
              let end = gregorian.date(byAdding: .day, value: ru.days.count - 1, to: first) else { return nil }
        return Day(end, calendar: gregorian)
    }

    /// По-английски — английские тексты, на остальных языках — русские (бурятских в «Зурхае» нет).
    public func day(_ day: Day, english: Bool = false) -> ZurkhaiDay? {
        let table = english ? en : ru
        let index = start.days(to: day)
        guard table.days.indices.contains(index) else { return nil }
        let row = table.days[index]
        guard row.count == 5, row[2...4].allSatisfy(table.strings.indices.contains) else { return nil }
        return ZurkhaiDay(lunarDay: row[0], haircutGood: row[1] == 1, haircut: table.strings[row[2]],
                          favorable: table.strings[row[3]], unfavorable: table.strings[row[4]])
    }
}
