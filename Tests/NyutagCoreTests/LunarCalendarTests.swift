// Нютаг. Лунный календарь: ближайший Сагаалган и день зурхая из сжатой таблицы.

import Foundation
import Testing
@testable import NyutagCore

@Suite struct LunarCalendarTests {
    @Test("ближайший Сагаалган: до, в день праздника и после")
    func nextSagaalgan() {
        let before = Sagaalgan.next(from: Day(year: 2026, month: 10, day: 21))
        #expect(before?.day == Day(year: 2027, month: 2, day: 7))
        #expect(before?.daysLeft == 109)
        #expect(Sagaalgan.next(from: Day(year: 2026, month: 2, day: 18))?.daysLeft == 0)
        #expect(Sagaalgan.next(from: Day(year: 2026, month: 1, day: 1))?.day == Day(year: 2026, month: 2, day: 18))
        #expect(Sagaalgan.next(from: Day(year: 2035, month: 3, day: 1)) == nil)
        #expect(Sagaalgan.upcoming(from: 2034).count == 2)
    }

    @Test("разница дней не зависит от часового пояса и високосных лет")
    func dayMath() {
        #expect(Day(year: 2027, month: 12, day: 31).days(to: Day(year: 2028, month: 3, day: 1)) == 61)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        var irkutsk = utc
        irkutsk.timeZone = TimeZone(identifier: "Asia/Irkutsk")!
        // 20:00 по Гринвичу — в Улан-Удэ уже следующие сутки.
        let evening = utc.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 20))!
        #expect(Day(evening, calendar: utc) == Day(year: 2026, month: 10, day: 14))
        #expect(Day(evening, calendar: irkutsk) == Day(year: 2026, month: 10, day: 15))
    }

    @Test("день зурхая: строки по номерам, вне таблицы — nil")
    func zurkhai() throws {
        let json = """
        {"from":"2026-01-01",
         "ru":{"strings":["К счастью","Учиться.","Рубить лес."],"days":[[13,1,0,1,2],[14,0,0,2,1]]},
         "en":{"strings":["Luck","Study.","Logging."],"days":[[13,1,0,1,2],[14,0,0,2,1]]}}
        """
        let days = try ZurkhaiDays(data: Data(json.utf8))
        let first = days.day(Day(year: 2026, month: 1, day: 1))
        #expect(first == ZurkhaiDay(lunarDay: 13, haircutGood: true, haircut: "К счастью", favorable: "Учиться.", unfavorable: "Рубить лес."))
        #expect(days.day(Day(year: 2026, month: 1, day: 2), english: true)?.favorable == "Logging.")
        #expect(days.day(Day(year: 2026, month: 1, day: 3)) == nil)
        #expect(days.day(Day(year: 2025, month: 12, day: 31)) == nil)
        #expect(days.last == Day(year: 2026, month: 1, day: 2))
    }

    @Test("настоящий файл приложения читается целиком: 2026–2027")
    func realFile() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../../App/Calendar/zurkhai-days.json").standardized
        let days = try ZurkhaiDays(data: Data(contentsOf: url))
        #expect(days.last == Day(year: 2027, month: 12, day: 31))
        #expect(days.day(Day(year: 2026, month: 1, day: 1))?.lunarDay == 13)
        #expect(days.day(Day(year: 2027, month: 12, day: 31), english: true) != nil)
    }
}
