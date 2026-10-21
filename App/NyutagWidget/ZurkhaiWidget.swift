// Нютаг. Виджет «Зурхай»: лунные сутки, стрижка и совет на сегодня, сколько дней до Сагаалгана.
// Данные те же, что во вкладке «Календарь» (`Calendar/zurkhai-days.json` в бандле виджета), обновление в полночь.
// Нажатие открывает вкладку «Календарь». Язык — по системе: по-английски английский текст, иначе русский
// (общей группы с приложением у виджета нет, выбор языка в приложении ему не виден).

import NyutagCore
import SwiftUI
import WidgetKit

struct ZurkhaiEntry: TimelineEntry {
    let date: Date
    let day: ZurkhaiDay?
    let daysLeft: Int?
}

struct ZurkhaiProvider: TimelineProvider {
    static let days: ZurkhaiDays? = Bundle.main.url(forResource: "zurkhai-days", withExtension: "json", subdirectory: "Calendar")
        .flatMap { try? Data(contentsOf: $0) }
        .flatMap { try? ZurkhaiDays(data: $0) }

    static func entry(at date: Date) -> ZurkhaiEntry {
        let today = Day(date)
        return ZurkhaiEntry(date: date, day: days?.day(today, english: WidgetText.english), daysLeft: Sagaalgan.next(from: today)?.daysLeft)
    }

    func placeholder(in context: Context) -> ZurkhaiEntry { Self.entry(at: .now) }

    func getSnapshot(in context: Context, completion: @escaping (ZurkhaiEntry) -> Void) { completion(Self.entry(at: .now)) }

    /// Сегодня и шесть следующих полуночей: виджет не ждёт приложение, чтобы перейти на новый день.
    func getTimeline(in context: Context, completion: @escaping (Timeline<ZurkhaiEntry>) -> Void) {
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: .now)
        var entries = [Self.entry(at: .now)]
        for offset in 1...6 {
            if let next = calendar.date(byAdding: .day, value: offset, to: midnight) { entries.append(Self.entry(at: next)) }
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

enum WidgetText {
    static let english = Locale.preferredLanguages.first?.hasPrefix("en") == true

    static var title: String { english ? "Zurkhai" : "Зурхай" }
    static func lunarDay(_ n: Int) -> String { english ? "Lunar day \(n)" : "\(n)-е лунные сутки" }
    static var haircut: String { english ? "Haircut" : "Стрижка" }
    static var favorable: String { english ? "Favorable" : "Благоприятно" }
    static func sagaalgan(_ days: Int) -> String {
        if days == 0 { return english ? "Sagaalgan today" : "Сегодня Сагаалган" }
        return english ? "Sagaalgan in \(days) d" : "До Сагаалгана \(days) дн."
    }
    static var noData: String { english ? "No data for this date" : "Нет данных на эту дату" }
    static var name: String { english ? "Zurkhai" : "Зурхай" }
    static var about: String { english ? "Lunar day, haircut and advice for today." : "Лунные сутки, стрижка и совет на сегодня." }
}

struct ZurkhaiWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ZurkhaiEntry

    private static let gold = Color(red: 0xC9 / 255, green: 0x97 / 255, blue: 0x1C / 255)
    private static let sky = Color(red: 0x23 / 255, green: 0x47 / 255, blue: 0xA6 / 255)

    var body: some View {
        content
            .containerBackground(for: .widget) { Color(.systemBackground) }
            .widgetURL(URL(string: "nyutag://calendar"))
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.day.map { WidgetText.lunarDay($0.lunarDay) } ?? WidgetText.title).font(.headline)
                if let day = entry.day { Text("\(WidgetText.haircut): \(day.haircut)").lineLimit(1) }
                if let left = entry.daysLeft { Text(WidgetText.sagaalgan(left)).lineLimit(1) }
            }
        case .accessoryInline:
            Text(entry.day.map { WidgetText.lunarDay($0.lunarDay) } ?? WidgetText.title)
        default:
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(WidgetText.title).font(.caption.weight(.semibold)).foregroundStyle(Self.gold)
                    Spacer(minLength: 4)
                    if let day = entry.day {
                        Image(systemName: "scissors").font(.caption).foregroundStyle(day.haircutGood ? Self.sky : .secondary)
                    }
                }
                if let day = entry.day {
                    Text(WidgetText.lunarDay(day.lunarDay)).font(.headline).lineLimit(2).minimumScaleFactor(0.8)
                    Text("\(WidgetText.haircut): \(day.haircut)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    if family == .systemMedium {
                        Text("\(WidgetText.favorable): \(day.favorable)").font(.caption).lineLimit(3)
                    }
                } else {
                    Text(WidgetText.noData).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let left = entry.daysLeft {
                    Text(WidgetText.sagaalgan(left)).font(.caption2.weight(.semibold)).foregroundStyle(Self.sky).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ZurkhaiWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "chat.nyutag.zurkhai", provider: ZurkhaiProvider()) { entry in
            ZurkhaiWidgetView(entry: entry)
        }
        .configurationDisplayName(WidgetText.name)
        .description(WidgetText.about)
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct NyutagWidgets: WidgetBundle {
    var body: some Widget { ZurkhaiWidget() }
}
