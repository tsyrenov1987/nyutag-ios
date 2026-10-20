// Нютаг. Главный экран: вкладки Чаты | Контакты | Сообщества, заголовок по центру, свой аватар слева открывает меню.
// Строка чата — карточка: аватар-подушка, имя, время, последняя реплика, галочки у своей, золотой счётчик.

import NyutagCore
import SwiftUI

struct HomeView: View {
    @Environment(Words.self) private var words

    var body: some View {
        TabView {
            Tab(words(.chats), systemImage: "bubble.left.and.bubble.right") { ChatListView() }
            Tab(words(.contacts), systemImage: "person.2") { SoonView(title: words(.contacts)) }
            Tab(words(.communities), systemImage: "circle.hexagongrid") { SoonView(title: words(.communities)) }
        }
    }
}

struct ChatListView: View {
    @Environment(Words.self) private var words
    @Environment(AppSession.self) private var session
    @State private var menu = false
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                if session.lines.isEmpty {
                    Text(words(.chatsEmpty))
                        .foregroundStyle(Theme.quiet)
                        .padding(.top, 120)
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(session.lines) { line in
                            NavigationLink(value: line.id) { ChatRow(line: line) }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("chat-\(line.id)")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                }
            }
            .background(Theme.milk.ignoresSafeArea())
            .navigationTitle(words(.chats))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { menu = true } label: {
                        Pillow(seed: session.me ?? "", title: ChatDigest.localpart(session.me ?? ""), size: 32)
                    }
                    .accessibilityIdentifier("me-menu")
                }
            }
            .navigationDestination(for: String.self) { roomID in ChatView(roomID: roomID) }
            .sheet(isPresented: $menu) { MeMenu() }
            #if DEBUG
            .onChange(of: session.lines.count, initial: true) { openForScreenshots() }
            #endif
        }
    }

    #if DEBUG
    /// Снимки экранов: открыть чат по части названия из SIMCTL_CHILD_NYUTAG_UI_OPEN_CHAT.
    private func openForScreenshots() {
        guard path.isEmpty, let wanted = ProcessInfo.processInfo.environment["NYUTAG_UI_OPEN_CHAT"],
              let line = session.lines.first(where: { $0.title.localizedCaseInsensitiveContains(wanted) }) else { return }
        path = [line.id]
        print("ui-check: открыт чат, событий в списке \(session.lines.count)")
    }
    #endif
}

struct ChatRow: View {
    @Environment(Words.self) private var words
    let line: ChatLine

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Pillow(seed: line.id, title: line.title.isEmpty ? "·" : line.title)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(line.title.isEmpty ? words(.emptyChat) : line.title)
                        .font(.headline).foregroundStyle(Theme.ink).lineLimit(1)
                    if line.isEncrypted {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(Theme.quiet)
                    }
                    Spacer(minLength: 4)
                    if line.lastIsMine { Ticks(delivery: line.delivery) }
                    if line.lastTS > 0 {
                        Text(Self.time(line.lastTS, words: words))
                            .font(.caption).monospacedDigit()
                            .foregroundStyle(line.unread > 0 ? Theme.gold : Theme.quiet)
                    }
                }
                HStack(alignment: .top, spacing: 6) {
                    Text(preview)
                        .font(.subheadline).foregroundStyle(Theme.quiet)
                        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    if line.mentions > 0 {
                        Text("@").font(.caption.bold()).foregroundStyle(.white)
                            .frame(minWidth: 22, minHeight: 22).background(Theme.sky, in: Capsule())
                    }
                    if line.unread > 0 {
                        Text(line.unread > 999 ? "999+" : "\(line.unread)")
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
    }

    private var preview: String {
        if line.membership == .invite { return words(.invited) }
        guard let last = line.last else { return words(.noMessages) }
        let body: String = switch last {
        case .text(let text): text
        case .image: "🖼 " + words(.image)
        case .video: "🎬 " + words(.video)
        case .audio: "🎙 " + words(.audio)
        case .file: "📎 " + words(.file)
        case .location: "📍 " + words(.location)
        case .poll: "📊 " + words(.poll)
        case .call: "📞 " + words(.call)
        default: Self.label(last, words: words)
        }
        if line.lastIsMine { return "\(words(.you)): \(body)" }
        if !line.isDirect, let name = line.lastSenderName { return "\(name): \(body)" }
        return body
    }

    /// Подпись вида реплики без значка: для цитаты, вложения в пузыре и списка.
    static func label(_ kind: PushPreview.Kind, words: Words) -> String {
        switch kind {
        case .text(let text): text
        case .image: words(.image)
        case .video: words(.video)
        case .audio: words(.audio)
        case .file: words(.file)
        case .location: words(.location)
        case .sticker: words(.sticker)
        case .poll: words(.poll)
        case .call: words(.call)
        case .invite: words(.invited)
        case .locked, .other: words(.newMessage)
        }
    }

    static func symbol(_ kind: PushPreview.Kind) -> String {
        switch kind {
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .location: "mappin.and.ellipse"
        case .sticker: "face.smiling"
        case .poll: "chart.bar"
        case .call: "phone"
        default: "paperclip"
        }
    }

    static func time(_ ms: Int, words: Words) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return words(.yesterday) }
        if let days = calendar.dateComponents([.day], from: date, to: .now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        let day = calendar.dateComponents([.day, .month], from: date)
        return String(format: "%02d.%02d", day.day ?? 0, day.month ?? 0)
    }
}

/// Своя реплика: одна галочка — дошла до сервера, две зелёные — прочитана.
struct Ticks: View {
    let delivery: ChatLine.Delivery
    /// На синем своём пузыре: серый и тёмно-зелёный там не читаются.
    var onBlue = false

    var body: some View {
        switch delivery {
        case .none: EmptyView()
        case .sent:
            Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(onBlue ? .white.opacity(0.75) : Theme.quiet)
        case .read:
            ZStack(alignment: .leading) {
                Image(systemName: "checkmark")
                Image(systemName: "checkmark").offset(x: 5)
            }
            .font(.caption2.bold()).foregroundStyle(onBlue ? Theme.readOnBlue : Theme.read).padding(.trailing, 5)
        }
    }
}

/// Меню под своим аватаром. Выход спрятан в «Дополнительно», не на виду.
struct MeMenu: View {
    @Environment(Words.self) private var words
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var askSignOut = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Pillow(seed: session.me ?? "", title: ChatDigest.localpart(session.me ?? ""), size: 64)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ChatDigest.localpart(session.me ?? "")).font(.title3.bold())
                            Text(session.me ?? "").font(.footnote).foregroundStyle(Theme.quiet)
                        }
                    }
                    .padding(.vertical, 6)
                }
                Section(words(.language)) {
                    ForEach(Lang.allCases) { lang in
                        Button { words.choose(lang) } label: {
                            HStack {
                                Text(lang.ownName).foregroundStyle(Theme.ink)
                                Spacer()
                                if words.lang == lang { Image(systemName: "checkmark").foregroundStyle(Theme.sky) }
                            }
                        }
                    }
                }
                Section(words(.advanced)) {
                    Button(words(.signOut)) { askSignOut = true }
                        .foregroundStyle(Theme.ink)
                        .accessibilityIdentifier("sign-out")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.milk.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(words(.done)) { dismiss() } }
            }
            .confirmationDialog(words(.signOutAsk), isPresented: $askSignOut, titleVisibility: .visible) {
                Button(words(.signOut)) {
                    dismiss()
                    Task { await session.signOut() }
                }
                Button(words(.cancel), role: .cancel) {}
            }
        }
    }
}

struct SoonView: View {
    @Environment(Words.self) private var words
    let title: String

    var body: some View {
        NavigationStack {
            Text(words(.soon))
                .foregroundStyle(Theme.quiet)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.milk.ignoresSafeArea())
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}
