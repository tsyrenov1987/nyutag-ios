// Нютаг. Экран чата: лента снизу вверх, пузыри-«листья» (острый угол у верхнего края со стороны автора),
// свои синие, чужие белые, оба контрастны к молочному фону. Служебное и дни — на плашках с подложкой.
// Отправка сразу показывает реплику с часиками; не ушла — подпись «нажмите, чтобы повторить».
// Долгое нажатие на пузырь: реакции строкой сверху, ответ, копия, а у своих — правка и удаление.

import NyutagCore
import SwiftUI

struct ChatView: View {
    @Environment(Words.self) private var words
    @Environment(AppSession.self) private var session
    let roomID: String

    @State private var items: [FeedItem] = []
    @State private var limit = 80
    @State private var hasOlder = true
    @State private var loadingOlder = false
    @State private var outbox: [Outgoing] = []
    @State private var draft = ""
    @State private var replyTo: FeedItem?
    @State private var editing: FeedItem?
    @State private var deleting: FeedItem?
    @State private var failed = false
    @State private var typingSentAt: Date?
    @State private var lastMarked: String?
    @FocusState private var typing: Bool

    struct Outgoing: Identifiable, Equatable {
        let id: String
        let text: String
        let replyTo: FeedItem?
        var eventID: String?
        var failed = false
    }

    private var line: ChatLine? { session.lines.first { $0.id == roomID } }
    private var isGroup: Bool { !(line?.isDirect ?? false) }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                if hasOlder {
                    ProgressView()
                        .padding(.vertical, 12)
                        .onAppear(perform: loadOlder)
                }
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    let previous = index > 0 ? items[index - 1] : nil
                    if previous.map({ !Calendar.current.isDate(day($0.ts), inSameDayAs: day(item.ts)) }) ?? true {
                        DayPlate(date: day(item.ts))
                    }
                    FeedRow(item: item, showsAuthor: isGroup && startsRun(item, after: previous)) { action in
                        act(action, on: item)
                    }
                }
                ForEach(outbox.filter { pending in !items.contains { $0.id == pending.eventID } }) { pending in
                    PendingBubble(pending: pending) { retry(pending) }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.milk.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .navigationTitle(line?.title.isEmpty == false ? line!.title : words(.emptyChat))
        .navigationSubtitle(typingLine)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(words(.deleteAsk), isPresented: Binding { deleting != nil } set: { if !$0 { deleting = nil } },
                            titleVisibility: .visible, presenting: deleting) { item in
            Button(words(.deleteAction), role: .destructive) { run { await session.delete(item.id, in: roomID) } }
            Button(words(.cancel), role: .cancel) {}
        }
        .alert(words(.cantDo), isPresented: $failed) { Button(words(.done)) {} }
        .onChange(of: draft) { noteTyping() }
        .onDisappear { stopTyping() }
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Pillow(seed: roomID, title: line?.title ?? "·", size: 32)
            }
        }
        .task(id: session.revision) {
            await reload()
            #if DEBUG
            sendForScreenshots()
            #endif
        }
    }

    // MARK: Поле ввода

    private var composer: some View {
        VStack(spacing: 0) {
            if let editing {
                banner(title: words(.editing), text: summary(editing.body), symbol: "pencil") {
                    self.editing = nil
                    draft = ""
                }
            } else if let replyTo {
                banner(title: replyTo.senderName, text: summary(replyTo.body), symbol: nil) { self.replyTo = nil }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(words(.messageField), text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($typing)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.milk, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .accessibilityIdentifier("chat-field")
                Button(action: sendDraft) {
                    Image(systemName: editing == nil ? "arrow.up" : "checkmark")
                        .font(.body.weight(.bold))
                        .foregroundStyle(Theme.onGold)
                        .frame(width: 40, height: 40)
                        .background(Theme.gold.opacity(canSend ? 1 : 0.4), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(!canSend)
                .accessibilityLabel(words(.send))
                .accessibilityIdentifier("chat-send")
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .background(Theme.card)
    }

    private func banner(title: String, text: String, symbol: String?, close: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            if let symbol { Image(systemName: symbol).font(.callout.bold()).foregroundStyle(Theme.sky) }
            Capsule().fill(Theme.sky).frame(width: 3, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.bold()).foregroundStyle(Theme.sky)
                Text(text).font(.caption).foregroundStyle(Theme.quiet).lineLimit(1)
            }
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark").font(.caption.bold()).foregroundStyle(Theme.quiet)
            }
            .accessibilityIdentifier("composer-close")
        }
        .padding(.horizontal, 16).padding(.top, 8)
    }

    private var canSend: Bool {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let editing, case .text(let old) = editing.body { return !text.isEmpty && text != old }
        return !text.isEmpty
    }

    /// Подпись под именем чата: кто набирает текст.
    private var typingLine: String {
        let who = session.typing[roomID] ?? []
        guard let first = who.first else { return "" }
        if !isGroup { return words(.typingNow) }
        let name = items.last { $0.sender == first }?.senderName ?? ChatDigest.localpart(first)
        return who.count == 1 ? words(.typingName, name) : words(.typingMany, name, "\(who.count - 1)")
    }

    // MARK: Действия

    private func reload() async {
        let fresh = await session.feed(roomID, limit: limit)
        if fresh != items { items = fresh }
        // Создание чата видно — раньше ничего нет.
        if case .notice(.created) = items.first?.body { hasOlder = false }
        outbox.removeAll { pending in pending.eventID.map { id in items.contains { $0.id == id } } ?? false }
        if let last = items.last(where: { !$0.isMine && !$0.isNotice }), last.id != lastMarked {
            lastMarked = last.id
            await session.markRead(roomID, upTo: last.id)
        }
    }

    private func loadOlder() {
        guard !loadingOlder else { return }
        loadingOlder = true
        Task {
            let before = items.count
            limit += 60
            await reload()
            // В базе кончилось — просим сервер.
            if hasOlder, items.count == before || items.count < limit / 2 {
                hasOlder = await session.older(roomID)
                await reload()
            }
            loadingOlder = false
        }
    }

    private func act(_ action: FeedRow.Action, on item: FeedItem) {
        switch action {
        case .reply:
            editing = nil
            replyTo = item
            typing = true
        case .edit:
            guard case .text(let text) = item.body else { return }
            replyTo = nil
            editing = item
            draft = text
            typing = true
        case .delete:
            deleting = item
        case .react(let key):
            run { await session.toggleReaction(key, on: item, in: roomID) }
        }
    }

    /// Действие с сервером; не вышло — короткое сообщение, вышло — лента перечитается со следующей синхронизацией.
    private func run(_ work: @escaping () async -> Bool) {
        Task {
            let done = await work()
            #if DEBUG
            print("ui-check: действие \(done ? "прошло" : "не прошло")")
            #endif
            if !done { failed = true }
        }
    }

    private func noteTyping() {
        guard editing == nil else { return }
        if draft.isEmpty { stopTyping(); return }
        // Сервер держит отметку 20 секунд; продлеваем не чаще раза в 8.
        guard typingSentAt.map({ Date.now.timeIntervalSince($0) > 8 }) ?? true else { return }
        typingSentAt = .now
        Task { await session.setTyping(true, in: roomID) }
    }

    private func stopTyping() {
        guard typingSentAt != nil else { return }
        typingSentAt = nil
        Task { await session.setTyping(false, in: roomID) }
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        if let editing {
            self.editing = nil
            draft = ""
            run { await session.edit(editing.id, text: text, in: roomID) }
            return
        }
        stopTyping()
        let pending = Outgoing(id: TransactionID.make(), text: text, replyTo: replyTo)
        draft = ""
        replyTo = nil
        outbox.append(pending)
        deliver(pending)
    }

    private func retry(_ pending: Outgoing) {
        guard pending.failed, let index = outbox.firstIndex(of: pending) else { return }
        outbox[index].failed = false
        deliver(outbox[index])
    }

    private func deliver(_ pending: Outgoing) {
        Task {
            let eventID = await session.send(pending.text, to: roomID, replyTo: pending.replyTo?.id, transactionID: pending.id)
            guard let index = outbox.firstIndex(where: { $0.id == pending.id }) else { return }
            if let eventID { outbox[index].eventID = eventID } else { outbox[index].failed = true }
            #if DEBUG
            print("ui-check: отправка \(eventID == nil ? "не прошла" : "прошла")")
            #endif
            await reload()
        }
    }

    #if DEBUG
    /// Самопроверка отправки: текст из SIMCTL_CHILD_NYUTAG_UI_SEND уходит один раз за запуск.
    private static var sentForScreenshots = false

    private func sendForScreenshots() {
        let env = ProcessInfo.processInfo.environment
        if let step = env["NYUTAG_UI_ACT"] { actForScreenshots(step) }
        guard !Self.sentForScreenshots, let text = env["NYUTAG_UI_SEND"] else { return }
        Self.sentForScreenshots = true
        draft = text
        sendDraft()
        print("ui-check: отправка ушла в очередь")
    }

    /// NYUTAG_UI_ACT над своей последней текстовой репликой, по одному шагу за запуск:
    /// `react:👍`, `edit:новый текст`, `delete`.
    private static var actedForScreenshots = false

    private func actForScreenshots(_ step: String) {
        guard !Self.actedForScreenshots, let target = items.last(where: \.canEdit) else { return }
        Self.actedForScreenshots = true
        let (verb, rest) = (step.prefix { $0 != ":" }, step.drop { $0 != ":" }.dropFirst())
        print("ui-check: действие \(verb) над \(target.id.prefix(8))…")
        switch verb {
        case "react": act(.react(String(rest)), on: target)
        case "edit":
            act(.edit, on: target)
            draft = String(rest)
            sendDraft()
        case "delete": run { await session.delete(target.id, in: roomID) }
        default: break
        }
    }
    #endif

    // MARK: Помощники

    private func day(_ ms: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(ms) / 1000) }

    /// Подпись автора — над первой репликой подряд от одного человека.
    private func startsRun(_ item: FeedItem, after previous: FeedItem?) -> Bool {
        guard !item.isMine, !item.isNotice else { return false }
        guard let previous, !previous.isNotice else { return true }
        return previous.sender != item.sender || item.ts - previous.ts > 10 * 60 * 1000
    }

    private func summary(_ body: FeedItem.Body) -> String {
        switch body {
        case .text(let text): text
        case .attachment(let kind, let caption): caption ?? ChatRow.label(kind, words: words)
        case .locked: words(.waitingKey)
        case .deleted: words(.deleted)
        case .notice: ""
        }
    }
}

/// Одна строка ленты: плашка или пузырь со своей стороны.
struct FeedRow: View {
    enum Action { case reply, edit, delete, react(String) }

    /// Быстрые реакции в меню, по порядку.
    static let quick = ["👍", "❤️", "😂", "😮", "😢", "🙏"]

    @Environment(Words.self) private var words
    let item: FeedItem
    let showsAuthor: Bool
    let perform: (Action) -> Void

    var body: some View {
        if case .notice(let notice) = item.body {
            Plate(text: NoticeText.make(notice, words: words))
        } else {
            HStack(alignment: .bottom, spacing: 0) {
                if item.isMine { Spacer(minLength: 56) }
                VStack(alignment: item.isMine ? .trailing : .leading, spacing: 4) {
                    Bubble(item: item, showsAuthor: showsAuthor)
                        .contextMenu { menu }
                    if !item.reactions.isEmpty {
                        Reactions(reactions: item.reactions) { key in perform(.react(key)) }
                    }
                }
                if !item.isMine { Spacer(minLength: 56) }
            }
            .padding(.top, showsAuthor ? 8 : 0)
        }
    }

    @ViewBuilder private var menu: some View {
        if item.body != .deleted, item.body != .locked {
            ControlGroup {
                ForEach(Self.quick, id: \.self) { key in
                    Button(key) { perform(.react(key)) }
                }
            }
            .controlGroupStyle(.palette)
        }
        Button(words(.reply), systemImage: "arrowshape.turn.up.left") { perform(.reply) }
        if case .text(let text) = item.body {
            Button(words(.copy), systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
        }
        if item.canEdit {
            Button(words(.editAction), systemImage: "pencil") { perform(.edit) }
        }
        if item.canDelete {
            Button(words(.deleteAction), systemImage: "trash", role: .destructive) { perform(.delete) }
        }
    }
}

struct Bubble: View {
    @Environment(Words.self) private var words
    let item: FeedItem
    let showsAuthor: Bool

    private var ink: Color { item.isMine ? .white : Theme.ink }
    private var soft: Color { item.isMine ? .white.opacity(0.75) : Theme.quiet }

    var body: some View {
        BubbleStack {
            if showsAuthor {
                Text(item.senderName).font(.caption.bold())
                    .foregroundStyle(Theme.avatarTints[Int(Pillow.stableHash(item.sender) % UInt32(Theme.avatarTints.count))])
            }
            if let quote = item.reply {
                HStack(spacing: 8) {
                    Capsule().fill(item.isMine ? .white : Theme.sky).frame(width: 3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(quote.senderName).font(.caption.bold())
                        Text(ChatRow.label(quote.preview, words: words)).font(.caption).lineLimit(1)
                    }
                    .foregroundStyle(soft)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            content
            HStack(spacing: 4) {
                if item.edited { Text(words(.edited)) }
                Text(Date(timeIntervalSince1970: TimeInterval(item.ts) / 1000), format: .dateTime.hour().minute())
                if item.isMine { Ticks(delivery: item.isRead ? .read : .sent, onBlue: true) }
            }
            .font(.caption2).monospacedDigit().foregroundStyle(soft)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .fixedSize(horizontal: false, vertical: true)
        .background(item.isMine ? Theme.mine : Theme.card, in: Leaf(mine: item.isMine))
        .shadow(color: .black.opacity(item.isMine ? 0 : 0.06), radius: 2, y: 1)
    }

    @ViewBuilder private var content: some View {
        switch item.body {
        case .text(let text):
            Text(text).foregroundStyle(ink).textSelection(.disabled)
        case .attachment(let kind, let caption):
            VStack(alignment: .leading, spacing: 4) {
                Label(ChatRow.label(kind, words: words), systemImage: ChatRow.symbol(kind)).foregroundStyle(ink)
                if let caption { Text(caption).foregroundStyle(ink) }
            }
        case .locked:
            Label(words(.waitingKey), systemImage: "key").font(.callout.italic()).foregroundStyle(soft)
        case .deleted:
            Label(words(.deleted), systemImage: "trash.slash").font(.callout.italic()).foregroundStyle(soft)
        case .notice:
            EmptyView()
        }
    }
}

/// Содержимое пузыря: ширина по самой широкой строке, всё слева, последняя строка (время) справа.
/// `VStack` с растянутой строкой времени раздувал бы любой пузырь до края экрана.
struct BubbleStack: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) }
        let height = sizes.map(\.height).reduce(0, +) + spacing * CGFloat(max(sizes.count - 1, 0))
        return CGSize(width: sizes.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            let x = index == subviews.count - 1 ? bounds.maxX - size.width : bounds.minX
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: bounds.width, height: nil))
            y += size.height + spacing
        }
    }
}

/// Пузырь-«лист»: все углы круглые, кроме верхнего со стороны автора.
struct Leaf: Shape {
    let mine: Bool

    func path(in rect: CGRect) -> Path {
        let big: CGFloat = 18, sharp: CGFloat = 4
        return UnevenRoundedRectangle(topLeadingRadius: mine ? big : sharp, bottomLeadingRadius: big,
                                      bottomTrailingRadius: big, topTrailingRadius: mine ? sharp : big,
                                      style: .continuous).path(in: rect)
    }
}

struct Reactions: View {
    let reactions: [FeedItem.Reaction]
    let toggle: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(reactions, id: \.key) { reaction in
                Button { toggle(reaction.key) } label: { chip(reaction) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("reaction-\(reaction.key)")
            }
        }
    }

    private func chip(_ reaction: FeedItem.Reaction) -> some View {
        HStack(spacing: 3) {
            Text(reaction.key)
            if reaction.count > 1 { Text("\(reaction.count)").font(.caption.bold()).monospacedDigit() }
        }
        .font(.callout)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .foregroundStyle(Theme.ink)
        .background(reaction.mine ? Theme.gold.opacity(0.35) : Theme.plate, in: Capsule())
    }
}

struct PendingBubble: View {
    @Environment(Words.self) private var words
    let pending: ChatView.Outgoing
    let onRetry: () -> Void

    var body: some View {
        HStack {
            Spacer(minLength: 56)
            VStack(alignment: .trailing, spacing: 4) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(pending.text).foregroundStyle(.white)
                    Image(systemName: pending.failed ? "exclamationmark.arrow.circlepath" : "clock")
                        .font(.caption2).foregroundStyle(.white.opacity(0.75))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .fixedSize(horizontal: false, vertical: true)
                .background(Theme.mine.opacity(pending.failed ? 0.55 : 0.85), in: Leaf(mine: true))
                if pending.failed {
                    Text(words(.notSent)).font(.caption).foregroundStyle(Theme.quiet)
                }
            }
            .onTapGesture(perform: onRetry)
        }
    }
}

struct Plate: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote.weight(.medium))
            .multilineTextAlignment(.center)
            .foregroundStyle(Theme.ink.opacity(0.8))
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Theme.plate, in: Capsule())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }
}

struct DayPlate: View {
    @Environment(Words.self) private var words
    let date: Date

    var body: some View {
        Group {
            if Calendar.current.isDateInToday(date) {
                Plate(text: words(.today))
            } else if Calendar.current.isDateInYesterday(date) {
                Plate(text: words(.yesterday))
            } else {
                Text(date, format: .dateTime.day().month(.wide))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.ink.opacity(0.8))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Theme.plate, in: Capsule())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
        }
    }
}

@MainActor
enum NoticeText {
    static func make(_ notice: FeedItem.Notice, words: Words) -> String {
        switch notice {
        case .created: words(.noticeCreated)
        case .joined(let who): words(.noticeJoined, who)
        case .left(let who): words(.noticeLeft, who)
        case .invited(let who, let by): words(.noticeInvited, who, by)
        case .removed(let who, let by): words(.noticeRemoved, who, by)
        case .banned(let who, let by): words(.noticeBanned, who, by)
        case .renamedSelf(let old, let new): words(.noticeRenamed, old, new)
        case .roomNamed(let title, _): words(.noticeRoomName, title)
        case .roomPhoto: words(.noticeRoomPhoto)
        case .roomTopic(let topic, _): words(.noticeTopic, topic)
        case .encryptionOn: words(.noticeEncrypted)
        }
    }
}
