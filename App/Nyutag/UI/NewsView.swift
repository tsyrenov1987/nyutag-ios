// Нютаг. «Новости Нютага»: обращения разработчика с сервера. В списке чатов — закреплённая строка сверху
// с числом непрочитанных, по касанию — карточки с кнопками (ссылка или «Поддержать Нютаг»).

import NyutagCore
import SwiftUI

/// Строка-канал в списке чатов: вид как у чата, но без комнаты за ней.
struct NewsRow: View {
    @Environment(Words.self) private var words
    @Environment(AppSession.self) private var session

    var body: some View {
        let latest = session.news.first
        let unread = session.unreadNews
        HStack(alignment: .top, spacing: 12) {
            NewsPillow()
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(words(.news)).font(.headline).foregroundStyle(Theme.ink).lineLimit(1)
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(Theme.quiet)
                        .rotationEffect(.degrees(45))
                        .accessibilityLabel(words(.pinned))
                    Spacer(minLength: 4)
                    if let from = latest?.from {
                        Text(Self.day(from, words: words))
                            .font(.caption).monospacedDigit()
                            .foregroundStyle(unread > 0 ? Theme.gold : Theme.quiet)
                    }
                }
                HStack(alignment: .top, spacing: 6) {
                    Text(latest?.title.text(lang) ?? words(.newsEmpty))
                        .font(.subheadline).foregroundStyle(Theme.quiet)
                        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    if unread > 0 {
                        Text("\(unread)")
                            .font(.caption.bold()).monospacedDigit().foregroundStyle(Theme.onGold)
                            .padding(.horizontal, 7).frame(minWidth: 22, minHeight: 22)
                            .background(Theme.gold, in: Capsule())
                    }
                }
            }
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat-news")
    }

    private var lang: String { words.lang?.rawValue ?? "ru" }

    static func day(_ date: Date, words: Words) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: words.lang?.locale ?? Locale(identifier: "ru")))
    }
}

struct NewsPillow: View {
    var size: CGFloat = 52

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.34, style: .continuous)
            .fill(Theme.gold.gradient)
            .overlay {
                Image(systemName: "megaphone.fill")
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Лента объявлений: свежие сверху, у каждого заголовок, дата, текст и кнопки.
struct NewsView: View {
    @Environment(Words.self) private var words
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var donating = false

    var body: some View {
        NavigationStack {
            ScrollView {
                if session.news.isEmpty {
                    VStack(spacing: 18) {
                        NewsPillow(size: 72)
                        Text(words(.newsEmpty)).foregroundStyle(Theme.quiet)
                    }
                    .padding(.top, 120)
                    .frame(maxWidth: .infinity)
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(session.news) { one in card(one) }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
            .background(Theme.milk.ignoresSafeArea())
            .navigationTitle(words(.news))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(words(.done)) { dismiss() } }
            }
            .sheet(isPresented: $donating) { DonateView() }
            .onAppear { session.markNewsSeen() }
        }
    }

    private var lang: String { words.lang?.rawValue ?? "ru" }

    private func card(_ one: Announcement) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(words(.newsFrom)).font(.caption).foregroundStyle(Theme.quiet)
                Spacer()
                if let from = one.from {
                    Text(NewsRow.day(from, words: words)).font(.caption).monospacedDigit().foregroundStyle(Theme.quiet)
                }
            }
            Text(one.title.text(lang)).font(.headline).foregroundStyle(Theme.ink)
            Text(one.body.text(lang)).font(.body).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if !one.actions.isEmpty {
                VStack(spacing: 8) {
                    ForEach(Array(one.actions.enumerated()), id: \.offset) { index, action in
                        Button {
                            switch action.kind {
                            case .url(let url): openURL(url)
                            case .donate: donating = true
                            }
                        } label: {
                            Label {
                                Text(action.label.text(lang)).fontWeight(.semibold)
                            } icon: {
                                Image(systemName: action.kind == .donate ? "heart.fill" : "arrow.up.right.square")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(action.kind == .donate ? Theme.gold : Theme.sky)
                        .accessibilityIdentifier("news-\(one.id)-\(index)")
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
