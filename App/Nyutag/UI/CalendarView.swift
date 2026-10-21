// Нютаг. Вкладка «Календарь»: сколько дней до Сагаалгана, какой год по восточному календарю, что говорит
// зурхай про сегодняшний день, и даты Сагаалгана на годы вперёд. Данные — из нашего приложения «Зурхай».

import NyutagCore
import SwiftUI

struct CalendarView: View {
    @Environment(Words.self) private var words
    @State private var today = Day(Date())

    private static let zurkhai: ZurkhaiDays? = Bundle.main.url(forResource: "zurkhai-days", withExtension: "json", subdirectory: "Calendar")
        .flatMap { try? Data(contentsOf: $0) }
        .flatMap { try? ZurkhaiDays(data: $0) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if let next = Sagaalgan.next(from: today) { sagaalganCard(next.day, daysLeft: next.daysLeft) }
                    if let day = Self.zurkhai?.day(today, english: words.lang == .en) { zurkhaiCard(day) }
                    yearsCard
                    Text(words(.zurkhaiSource))
                        .font(.footnote).foregroundStyle(Theme.quiet)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .background(Theme.milk.ignoresSafeArea())
            .navigationTitle(words(.calendar))
            .navigationBarTitleDisplayMode(.inline)
        }
        // Вкладку могут держать открытой через полночь.
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in today = Day(Date()) }
        .onAppear {
            today = Day(Date())
            #if DEBUG
            let next = Sagaalgan.next(from: today)
            print("ui-check: календарь: Сагаалган \(next.map { "\($0.day.year)-\($0.day.month)-\($0.day.day), через \($0.daysLeft)" } ?? "нет"), зурхай \(Self.zurkhai?.day(today).map { "\($0.lunarDay)-е сутки" } ?? "нет")")
            #endif
        }
    }

    private func sagaalganCard(_ day: Day, daysLeft: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(words(.sagaalgan)).font(.title2.bold()).foregroundStyle(Theme.onGold)
                Spacer()
                Text(format(day)).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.onGold.opacity(0.8))
            }
            Text(words(.eastYearOf, words.eastYear(EastYear(year: day.year))))
                .font(.subheadline).foregroundStyle(Theme.onGold.opacity(0.85))
            Text(daysLeft == 0 ? words(.sagaalganToday) : words(.sagaalganLeft, "\(daysLeft)"))
                .font(.title3.weight(.semibold)).foregroundStyle(Theme.onGold)
                .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.gold.gradient, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("calendar-sagaalgan")
    }

    private func zurkhaiCard(_ day: ZurkhaiDay) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(words(.zurkhaiToday)).font(.headline).foregroundStyle(Theme.ink)
                Spacer()
                Text(words(.lunarDay, "\(day.lunarDay)")).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.sky)
            }
            row(symbol: "scissors", tint: day.haircutGood ? Theme.read : Theme.quiet, title: words(.haircut), text: day.haircut)
            row(symbol: "sun.max", tint: Theme.gold, title: words(.favorable), text: day.favorable)
            row(symbol: "cloud", tint: Theme.quiet, title: words(.unfavorable), text: day.unfavorable)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityIdentifier("calendar-zurkhai")
    }

    private func row(symbol: String, tint: Color, title: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(Theme.quiet)
                Text(text).font(.body).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var yearsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(words(.sagaalganYears)).font(.headline).foregroundStyle(Theme.ink).padding(.bottom, 8)
            ForEach(Sagaalgan.upcoming(from: today.year).filter { $0 >= today }, id: \.year) { day in
                HStack {
                    Text(format(day)).foregroundStyle(Theme.ink)
                    Spacer()
                    Text(words.eastYear(EastYear(year: day.year))).foregroundStyle(Theme.quiet)
                }
                .font(.subheadline)
                .padding(.vertical, 7)
                if day.year != Sagaalgan.years.upperBound { Divider() }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func format(_ day: Day) -> String {
        let date = Calendar.current.date(from: DateComponents(year: day.year, month: day.month, day: day.day)) ?? .now
        return date.formatted(Date.FormatStyle(date: .long, time: .omitted, locale: words.lang?.locale ?? Locale(identifier: "ru")))
    }
}
