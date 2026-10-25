// Нютаг. Главный экран: вкладки Чаты | Контакты | Сообщества | Календарь, заголовок по центру, свой аватар слева открывает меню.
// Строка чата — карточка: аватар-подушка, имя, время, последняя реплика, галочки у своей, золотой счётчик.

import NyutagCore
import SwiftUI

struct HomeView: View {
    @Environment(Words.self) private var words
    @Environment(AppSession.self) private var session
    @State private var tab = 0
    @State private var whereFrom = false

    var body: some View {
        // Свёрнутый звонок — над вкладками, а не поверх: заголовки и списки уходят под него, не просвечивая.
        VStack(spacing: 6) {
            if session.calls.showsStrip { CallStrip() }
            TabView(selection: $tab) {
                Tab(words(.chats), systemImage: "bubble.left.and.bubble.right", value: 0) { ChatListView() }
                Tab(words(.contacts), systemImage: "person.2", value: 1) { ContactsView() }
                Tab(words(.communities), systemImage: "circle.hexagongrid", value: 2) { CommunitiesView() }
                Tab(words(.calendar), systemImage: "moon.stars", value: 3) { CalendarView() }
            }
        }
        .background(Theme.milk.ignoresSafeArea())
        .onChange(of: PushDoor.shared.tappedRoom) { if PushDoor.shared.tappedRoom != nil { tab = 0 } }
        .onChange(of: session.requestedTab, initial: true) {
            guard let requested = session.requestedTab else { return }
            tab = requested
            session.requestedTab = nil
        }
        .onChange(of: session.revision > 0, initial: true) {
            // После первого /sync список сообществ настоящий: кто уже в нютаге, того не спрашиваем.
            guard session.revision > 0, !UserDefaults.standard.bool(forKey: WhereFromView.doneKey) else { return }
            UserDefaults.standard.set(true, forKey: WhereFromView.doneKey)
            if session.communities.isEmpty { whereFrom = true }
        }
        .sheet(isPresented: $whereFrom) { WhereFromView() }
        .animation(.smooth, value: session.calls.showsStrip)
        .fullScreenCover(isPresented: .constant(session.calls.current != nil && !session.calls.folded)) { CallView() }
        .sheet(isPresented: Bindable(session).showDeviceCheck, onDismiss: { Task { await session.closeDeviceCheck() } }) {
            DeviceCheckView()
        }
        #if DEBUG
        .onAppear {
            if ProcessInfo.processInfo.environment["NYUTAG_UI_CONTACTS"] != nil { tab = 1 }
            if ProcessInfo.processInfo.environment["NYUTAG_UI_COMMUNITY"] != nil { tab = 2 }
            if ProcessInfo.processInfo.environment["NYUTAG_UI_CALENDAR"] != nil { tab = 3 }
        }
        // Сброс пароля живёт на экране входа; NYUTAG_UI_RESET показывает его и без выхода из аккаунта.
        .sheet(isPresented: .constant(ProcessInfo.processInfo.environment["NYUTAG_UI_RESET"] != nil)) { PasswordResetView() }
        .task {
            // Самопроверка: NYUTAG_UI_DEVICE=ask — попросить подтверждение у своих устройств, когда машина поднимется.
            guard ProcessInfo.processInfo.environment["NYUTAG_UI_DEVICE"] == "ask" else { return }
            try? await Task.sleep(for: .seconds(6))
            session.showDeviceCheck = true
        }
        #endif
    }
}

struct ChatListView: View {
    @Environment(Words.self) private var words
    @Environment(AppSession.self) private var session
    @State private var menu = false
    @State private var path: [String] = []
    @State private var signingInAgain = false
    /// Открытая папка; `nil` — «Все».
    @State private var folder: String?
    @State private var naming: FolderNaming?
    @State private var folderName = ""
    @State private var deleting: ChatFolder?
    @State private var creatingGroup = false
    @State private var leaving: String?
    @State private var showingNews = false
    @State private var query = ""
    @State private var hits: [SearchHit] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    searchResults
                } else {
                if !session.layout.folders.isEmpty {
                    FolderBar(selected: $folder, naming: $naming, deleting: $deleting)
                        .padding(.top, 2)
                }
                if session.historyNeedsSignIn {
                    LockedHistoryCard { signingInAgain = true }
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                }
                if folder == nil, !session.news.isEmpty {
                    Button { showingNews = true } label: { NewsRow() }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                }
                let shown = session.layout.arrange(session.lines, folder: folder)
                if shown.isEmpty {
                    VStack(spacing: 18) {
                        if folder == nil { NyutagLogo(size: 72) }
                        Text(words(folder == nil ? .chatsEmpty : .folderEmpty))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Theme.quiet)
                    }
                    .padding(.top, 120)
                    .padding(.horizontal, 32)
                    .frame(maxWidth: .infinity)
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(shown) { line in
                            NavigationLink(value: line.id) { ChatRow(line: line) }
                                .buttonStyle(.plain)
                                .contextMenu { rowMenu(line.id) }
                                .accessibilityIdentifier("chat-\(line.id)")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.milk.ignoresSafeArea())
            .searchable(text: $query, prompt: words(.searchChats))
            .task(id: query) {
                let wanted = query.trimmingCharacters(in: .whitespaces)
                guard wanted.count >= 2 else { hits = []; return }
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                let found = await session.search(wanted)
                if !Task.isCancelled { hits = found }
                #if DEBUG
                print("ui-check: поиск «\(wanted)»: чатов \(matchingChats.count), сообщений \(found.count)")
                if ProcessInfo.processInfo.environment["NYUTAG_UI_SEARCH_OPEN"] != nil, let first = found.first {
                    open(first)
                }
                #endif
            }
            .navigationTitle(words(.chats))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { menu = true } label: {
                        Pillow(seed: session.me ?? "", title: ChatDigest.localpart(session.me ?? ""), size: 32,
                               avatar: session.myAvatarURL)
                    }
                    .accessibilityIdentifier("me-menu")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(words(.groupNew), systemImage: "square.and.pencil") { creatingGroup = true }
                        .accessibilityIdentifier("new-group")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(words(.savedMessages), systemImage: "bookmark") { openSaved() }
                        .accessibilityIdentifier("saved-messages")
                }
            }
            .navigationDestination(for: String.self) { roomID in ChatView(roomID: roomID) }
            .sheet(isPresented: $menu) { MeMenu(onSaved: openSaved) }
            .sheet(isPresented: $creatingGroup) { GroupCreateView { path = [$0] } }
            .sheet(isPresented: $showingNews) { NewsView() }
            .confirmationDialog(words(.chatLeave), isPresented: Binding { leaving != nil } set: { if !$0 { leaving = nil } },
                                titleVisibility: .visible, presenting: leaving) { roomID in
                Button(words(.chatLeave), role: .destructive) { Task { await session.leaveChat(roomID) } }
                Button(words(.cancel), role: .cancel) {}
            } message: { _ in Text(words(.chatLeaveHint)) }
            .confirmationDialog(words(.historyLockedTitle), isPresented: $signingInAgain, titleVisibility: .visible) {
                Button(words(.signOut), role: .destructive) { Task { await session.signOut() } }
                Button(words(.cancel), role: .cancel) {}
            } message: { Text(words(.historySignInAgain)) }
            .alert(words(naming?.isNew == false ? .folderRename : .folderNew), isPresented: $naming.present()) {
                TextField(words(.folderName), text: $folderName)
                Button(words(.save)) { saveFolder() }
                Button(words(.cancel), role: .cancel) {}
            }
            .onChange(of: naming) { if let naming { folderName = naming.oldName ?? "" } }
            .confirmationDialog(words(.folderDelete), isPresented: $deleting.present(), titleVisibility: .visible,
                                presenting: deleting) { gone in
                Button(words(.folderDelete), role: .destructive) {
                    if folder == gone.id { folder = nil }
                    Task { await session.deleteFolder(gone.id) }
                }
                Button(words(.cancel), role: .cancel) {}
            } message: { _ in Text(words(.folderDeleteHint)) }
            .onChange(of: session.layout.folders) {
                // Папку удалили на другом устройстве — возвращаемся во «Все».
                if let folder, !session.layout.folders.contains(where: { $0.id == folder }) { self.folder = nil }
            }
            .onChange(of: PushDoor.shared.tappedRoom, initial: true) {
                // Коснулись уведомления: открыть его чат поверх того, что было открыто.
                guard let room = PushDoor.shared.tappedRoom else { return }
                PushDoor.shared.tappedRoom = nil
                path = [room]
            }
            #if DEBUG
            .onChange(of: session.lines.count, initial: true) { openForScreenshots() }
            .task { await tryLayout() }
            .task {
                let env = ProcessInfo.processInfo.environment
                if env["NYUTAG_UI_DELETE_ACCOUNT"] != nil {
                    // Свежая учётка без чатов: ждём только вход.
                    while session.phase != .signedIn { try? await Task.sleep(for: .milliseconds(300)) }
                    menu = true
                    return
                }
                guard env["NYUTAG_UI_INVITE"] != nil || env["NYUTAG_UI_ABOUT"] != nil || env["NYUTAG_UI_DONATE"] != nil
                        || env["NYUTAG_UI_AVATAR"] != nil || env["NYUTAG_UI_DEVICES"] != nil || env["NYUTAG_UI_ME"] != nil else { return }
                while session.lines.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
                menu = true
            }
            .task {
                guard let wanted = ProcessInfo.processInfo.environment["NYUTAG_UI_SEARCH"] else { return }
                while session.lines.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
                // Индекс поиска собирается в фоне после первого списка: даём ему время.
                try? await Task.sleep(for: .seconds(5))
                query = wanted
            }
            .task {
                guard ProcessInfo.processInfo.environment["NYUTAG_UI_NEWS"] != nil else { return }
                while session.news.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
                try? await Task.sleep(for: .seconds(1))
                showingNews = true
            }
            .task {
                guard ProcessInfo.processInfo.environment["NYUTAG_UI_GROUP"] != nil else { return }
                while session.lines.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
                creatingGroup = true
            }
            .task {
                guard ProcessInfo.processInfo.environment["NYUTAG_UI_SAVED"] != nil else { return }
                while session.lines.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
                openSaved()
            }
            #endif
        }
    }

    @ViewBuilder private func rowMenu(_ roomID: String) -> some View {
        let layout = session.layout
        if layout.isPinned(roomID) {
            Button(words(.unpin), systemImage: "pin.slash") { Task { await session.setPinned(roomID, false) } }
        } else if layout.canPinMore {
            Button(words(.pin), systemImage: "pin") { Task { await session.setPinned(roomID, true) } }
        } else {
            Button(words(.pinLimit), systemImage: "pin") {}.disabled(true)
        }
        Menu(words(.folderAdd), systemImage: "folder") {
            ForEach(layout.folders) { item in
                let inside = item.rooms.contains(roomID)
                Button(item.name, systemImage: inside ? "checkmark" : "folder") {
                    Task { await session.place(roomID, in: item.id, !inside) }
                }
            }
            Button(words(.folderNew), systemImage: "folder.badge.plus") { naming = FolderNaming(roomID: roomID) }
        }
        if roomID != session.savedRoom {
            if session.isMuted(roomID) {
                Button(words(.unmute), systemImage: "bell") { Task { await session.setMuted(roomID, false) } }
            } else {
                Button(words(.mute), systemImage: "bell.slash") { Task { await session.setMuted(roomID, true) } }
            }
            Divider()
            Button(words(.chatLeave), systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { leaving = roomID }
        }
    }

    private func openSaved() {
        Task {
            guard let roomID = await session.openSaved(name: words(.savedMessages), topic: words(.savedMessagesTopic)) else { return }
            path = [roomID]
            #if DEBUG
            print("ui-check: открыто избранное")
            #endif
        }
    }

    private func saveFolder() {
        guard let naming else { return }
        let name = folderName
        Task {
            if let id = naming.folderID {
                await session.renameFolder(id, to: name)
            } else {
                await session.addFolder(name, with: naming.roomID)
            }
        }
    }

    #if DEBUG
    /// Самопроверка закрепа и папок: NYUTAG_UI_LAYOUT=pin — закрепить последний чат списка, folder — ещё и папка
    /// «Проверка» с ним, открыть её; clear — убрать всё. Пишет на сервер, как живое меню.
    private func tryLayout() async {
        guard let mode = ProcessInfo.processInfo.environment["NYUTAG_UI_LAYOUT"] else { return }
        while session.lines.count < 2 { try? await Task.sleep(for: .milliseconds(300)) }
        try? await Task.sleep(for: .seconds(3))
        if mode == "clear" {
            for pin in session.layout.pins { await session.setPinned(pin, false) }
            for item in session.layout.folders { await session.deleteFolder(item.id) }
        } else if let last = session.lines.last {
            await session.setPinned(last.id, true)
            if mode == "folder" {
                await session.addFolder("Проверка", with: last.id)
                folder = session.layout.folders.first { $0.name == "Проверка" }?.id
            }
        }
        print("ui-check: раскладка \(mode): закреплено \(session.layout.pins.count), папок \(session.layout.folders.count), сверху \(session.layout.arrange(session.lines).first?.title ?? "-")")
    }

    /// Снимки экранов: открыть чат по части названия из SIMCTL_CHILD_NYUTAG_UI_OPEN_CHAT.
    private func openForScreenshots() {
        guard path.isEmpty, let wanted = ProcessInfo.processInfo.environment["NYUTAG_UI_OPEN_CHAT"],
              let line = session.lines.first(where: { ($0.title.isEmpty ? words(.emptyChat) : $0.title).localizedCaseInsensitiveContains(wanted) }) else { return }
        path = [line.id]
        print("ui-check: открыт чат, событий в списке \(session.lines.count)")
    }
    #endif
}

extension ChatListView {
    /// Чаты, у которых совпало название.
    private var matchingChats: [ChatLine] {
        let wanted = Search.fold(query.trimmingCharacters(in: .whitespaces))
        guard !wanted.isEmpty else { return [] }
        return session.lines.filter { $0.membership == .join && Search.fold($0.title).contains(wanted) }
    }

    @ViewBuilder private var searchResults: some View {
        let chats = matchingChats
        LazyVStack(alignment: .leading, spacing: 8) {
            if chats.isEmpty, hits.isEmpty {
                Text(words(.searchNothing))
                    .foregroundStyle(Theme.quiet)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
            }
            if !chats.isEmpty {
                Text(words(.chats)).font(.footnote.bold()).foregroundStyle(Theme.quiet).padding(.leading, 6)
                ForEach(chats) { line in
                    NavigationLink(value: line.id) { ChatRow(line: line) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("found-chat-\(line.id)")
                }
            }
            if !hits.isEmpty {
                Text(words(.searchMessages)).font(.footnote.bold()).foregroundStyle(Theme.quiet)
                    .padding(.leading, 6).padding(.top, chats.isEmpty ? 0 : 8)
                ForEach(hits) { hit in
                    Button { open(hit) } label: { SearchHitRow(hit: hit, query: query) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("found-\(hit.eventID)")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    private func open(_ hit: SearchHit) {
        session.jump = (hit.roomID, hit.eventID)
        path = [hit.roomID]
    }
}

/// Найденная реплика: чат, автор (в группе), текст и время.
struct SearchHitRow: View {
    @Environment(Words.self) private var words
    @Environment(AppSession.self) private var session
    let hit: SearchHit
    let query: String

    var body: some View {
        let line = session.lines.first { $0.id == hit.roomID }
        HStack(alignment: .top, spacing: 12) {
            if hit.roomID == session.savedRoom {
                SavedPillow(size: 44)
            } else {
                Pillow(seed: hit.roomID, title: line?.title ?? "·", size: 44, avatar: line?.avatarURL)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(line?.title.isEmpty == false ? line!.title : words(.emptyChat))
                        .font(.subheadline.bold()).foregroundStyle(Theme.ink).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(ChatRow.time(hit.ts, words: words)).font(.caption).monospacedDigit().foregroundStyle(Theme.quiet)
                }
                if line?.isDirect == false, hit.sender != session.me {
                    Text(ChatDigest.localpart(hit.sender)).font(.caption).foregroundStyle(Theme.sky)
                }
                Text(highlighted).font(.subheadline).foregroundStyle(Theme.quiet).lineLimit(2)
            }
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// Текст реплики с выделенным совпадением.
    private var highlighted: AttributedString {
        var text = AttributedString(hit.text)
        let wanted = query.trimmingCharacters(in: .whitespaces)
        if let range = text.range(of: wanted, options: [.caseInsensitive, .diacriticInsensitive]) {
            text[range].foregroundColor = Theme.ink
            text[range].font = .subheadline.bold()
        }
        return text
    }
}

struct ChatRow: View {
    @Environment(Words.self) private var words
    @Environment(AppSession.self) private var session
    let line: ChatLine

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if line.id == session.savedRoom {
                SavedPillow()
            } else {
                Pillow(seed: line.id, title: line.title.isEmpty ? "·" : line.title, avatar: line.avatarURL)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if !line.isDirect, line.id != session.savedRoom {
                        Image(systemName: line.community == nil ? "person.2.fill" : "person.3.fill")
                            .font(.caption).foregroundStyle(Theme.quiet)
                            .accessibilityLabel(words(line.community == nil ? .groupBadge : .communityBadge))
                    }
                    Text(line.title.isEmpty ? words(.emptyChat) : line.title)
                        .font(.headline).foregroundStyle(Theme.ink).lineLimit(1)
                    if line.isEncrypted {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(Theme.quiet)
                    }
                    if session.layout.isPinned(line.id) {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(Theme.quiet)
                            .rotationEffect(.degrees(45))
                            .accessibilityLabel(words(.pinned))
                    }
                    if session.isMuted(line.id) {
                        Image(systemName: "bell.slash.fill").font(.caption2).foregroundStyle(Theme.quiet)
                            .accessibilityLabel(words(.muted))
                    }
                    Spacer(minLength: 4)
                    if line.lastIsMine { Ticks(delivery: line.delivery) }
                    if line.lastTS > 0 {
                        Text(Self.time(line.lastTS, words: words))
                            .font(.caption).monospacedDigit()
                            .foregroundStyle(line.unread > 0 ? Theme.gold : Theme.quiet)
                    }
                }
                if let community = line.community, community != line.title {
                    Text(community).font(.caption.weight(.semibold)).foregroundStyle(Theme.sky).lineLimit(1)
                        .padding(.top, -2)
                }
                HStack(alignment: .top, spacing: 6) {
                    Text(typing ?? preview)
                        .font(.subheadline).foregroundStyle(typing == nil ? Theme.quiet : Theme.sky)
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

    /// Кто-то набирает текст — это важнее последней реплики.
    private var typing: String? {
        guard let first = session.typing[line.id]?.first else { return nil }
        guard !line.isDirect else { return words(.typingNow) }
        return words(.typingName, ChatDigest.localpart(first))
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
        case .locked, .other, .signal: words(.newMessage)
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

/// Новая папка (с чатом, из меню которого её завели) или переименование старой.
struct FolderNaming: Equatable {
    var folderID: String?
    var oldName: String?
    var roomID: String?
    var isNew: Bool { folderID == nil }
}

/// Полоса папок над списком: «Все», папки, «+». Зажатая папка — переименовать или удалить.
struct FolderBar: View {
    @Environment(Words.self) private var words
    @Environment(AppSession.self) private var session
    @Binding var selected: String?
    @Binding var naming: FolderNaming?
    @Binding var deleting: ChatFolder?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(words(.folderAll), on: selected == nil) { selected = nil }
                    .accessibilityIdentifier("folder-all")
                ForEach(session.layout.folders) { folder in
                    chip(folder.name, on: selected == folder.id) { selected = folder.id }
                        .contextMenu {
                            Button(words(.folderRename), systemImage: "pencil") {
                                naming = FolderNaming(folderID: folder.id, oldName: folder.name)
                            }
                            Button(words(.folderDelete), systemImage: "trash", role: .destructive) { deleting = folder }
                        }
                        .accessibilityIdentifier("folder-\(folder.name)")
                }
                Button { naming = FolderNaming() } label: {
                    Image(systemName: "plus").font(.subheadline.bold()).foregroundStyle(Theme.quiet)
                        .frame(width: 34, height: 34).background(Theme.card, in: Circle())
                }
                .accessibilityLabel(words(.folderNew))
            }
            .padding(.horizontal, 12)
        }
    }

    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(on ? .semibold : .regular)).lineLimit(1)
                .foregroundStyle(on ? .white : Theme.ink)
                .padding(.horizontal, 14).frame(height: 34)
                .background(on ? Theme.sky : Theme.card, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

extension Binding {
    /// Окно открыто, пока есть что показать; закрыли — значение сбрасывается.
    func present<Wrapped>() -> Binding<Bool> where Value == Wrapped? {
        Binding<Bool>(get: { wrappedValue != nil }, set: { if !$0 { wrappedValue = nil } })
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
    static let version: String = {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "") (\(info?["CFBundleVersion"] as? String ?? ""))"
    }()

    @Environment(Words.self) private var words
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var askSignOut = false
    @State private var deletingAccount = false
    @State private var inviting = false
    @State private var choosingWallpaper = false
    @State private var donating = false
    @State private var editingProfile = false
    @State private var showingDevices = false
    /// Имя из профиля; пока не загрузилось (или не задано) — логин.
    @State private var myName: String?
    let onSaved: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        ProfileEditView()
                    } label: {
                        HStack(spacing: 14) {
                            Pillow(seed: session.me ?? "", title: myName ?? ChatDigest.localpart(session.me ?? ""), size: 64,
                                   avatar: session.myAvatarURL)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(myName ?? ChatDigest.localpart(session.me ?? "")).font(.title3.bold())
                                Text(session.me ?? "").font(.footnote).foregroundStyle(Theme.quiet)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .accessibilityIdentifier("menu-profile")
                    .task {
                        guard let me = session.me, let name = await session.profile(of: me)?.displayName else { return }
                        myName = name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : name
                    }
                }
                Section {
                    Button {
                        dismiss()
                        onSaved()
                    } label: {
                        Label { Text(words(.savedMessages)).foregroundStyle(Theme.ink) } icon: {
                            Image(systemName: "bookmark.fill").foregroundStyle(Theme.sky)
                        }
                    }
                    .accessibilityIdentifier("menu-saved")
                    Button { inviting = true } label: {
                        Label { Text(words(.inviteFriend)).foregroundStyle(Theme.ink) } icon: {
                            Image(systemName: "person.badge.plus").foregroundStyle(Theme.sky)
                        }
                    }
                    .accessibilityIdentifier("menu-invite")
                    Button { choosingWallpaper = true } label: {
                        Label { Text(words(.wallpaper)).foregroundStyle(Theme.ink) } icon: {
                            Image(systemName: "paintpalette").foregroundStyle(Theme.sky)
                        }
                    }
                    .accessibilityIdentifier("menu-wallpaper")
                    Button { donating = true } label: {
                        Label { Text(words(.donate)).foregroundStyle(Theme.ink) } icon: {
                            Image(systemName: "heart.fill").foregroundStyle(Theme.gold)
                        }
                    }
                    .accessibilityIdentifier("menu-donate")
                }
                Section {
                    ForEach(Lang.allCases) { lang in
                        Button { words.choose(lang) } label: {
                            HStack {
                                Text(lang.ownName).foregroundStyle(Theme.ink)
                                Spacer()
                                if words.lang == lang { Image(systemName: "checkmark").foregroundStyle(Theme.sky) }
                            }
                        }
                    }
                    Toggle(words(.buryatLetters), isOn: Bindable(words).buryatLetters)
                        .tint(Theme.gold)
                        .accessibilityIdentifier("menu-bxr-letters")
                } header: {
                    Text(words(.language))
                } footer: {
                    Text(words(.buryatLettersHint))
                }
                Section(words(.advanced)) {
                    Button { showingDevices = true } label: {
                        Label(words(.devices), systemImage: "iphone.and.ipad").foregroundStyle(Theme.ink)
                    }
                    .accessibilityIdentifier("menu-devices")
                    Button(words(.signOut)) { askSignOut = true }
                        .foregroundStyle(Theme.ink)
                        .accessibilityIdentifier("sign-out")
                    Button(words(.deleteAccount), role: .destructive) { deletingAccount = true }
                        .accessibilityIdentifier("delete-account")
                }
                Section {
                    VStack(spacing: 8) {
                        NyutagLogo(size: 44)
                        Text("Нютаг \(Self.version)").font(.footnote).foregroundStyle(Theme.quiet)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.milk.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(words(.done)) { dismiss() } }
            }
            .navigationDestination(isPresented: $editingProfile) { ProfileEditView() }
            .navigationDestination(isPresented: $showingDevices) { DevicesView() }
            .sheet(isPresented: $inviting) { InviteView() }
            .sheet(isPresented: $choosingWallpaper) { WallpaperPicker() }
            .sheet(isPresented: $donating) { DonateView() }
            .sheet(isPresented: $deletingAccount) { DeleteAccountView() }
            #if DEBUG
            .onAppear {
                if ProcessInfo.processInfo.environment["NYUTAG_UI_INVITE"] != nil { inviting = true }
                if ProcessInfo.processInfo.environment["NYUTAG_UI_DELETE_ACCOUNT"] != nil { deletingAccount = true }
                if ProcessInfo.processInfo.environment["NYUTAG_UI_DONATE"] != nil { donating = true }
                if ProcessInfo.processInfo.environment["NYUTAG_UI_DEVICES"] != nil { showingDevices = true }
                if ProcessInfo.processInfo.environment["NYUTAG_UI_ABOUT"] != nil { editingProfile = true }
                if ProcessInfo.processInfo.environment["NYUTAG_UI_AVATAR"] != nil { editingProfile = true }
            }
            #endif
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

/// Удаление аккаунта: предупреждение, пароль, красная кнопка. После удаления приложение само уходит на экран входа.
struct DeleteAccountView: View {
    @Environment(Words.self) private var words
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var busy = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(words(.deleteAccountLead)).foregroundStyle(Theme.ink)
                    Text(words(.deleteAccountPassword)).font(.footnote).foregroundStyle(Theme.quiet)
                    SecureField(words(.password), text: $password)
                        .textContentType(.password)
                        .padding(16)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .accessibilityIdentifier("delete-account-password")
                    if let failure { FailureNote(text: failure) }
                    Button {
                        Task { await deleteAccount() }
                    } label: {
                        HStack {
                            if busy { ProgressView().tint(.white) }
                            Text(words(.deleteAccount)).font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(busy || password.isEmpty)
                    .accessibilityIdentifier("delete-account-confirm")
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.milk.ignoresSafeArea())
            .navigationTitle(words(.deleteAccount))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(words(.cancel)) { dismiss() } }
            }
            #if DEBUG
            // Самопроверка: NYUTAG_UI_DELETE_ACCOUNT=<пароль> — удаляем без касаний (пустое значение только открывает экран).
            .task {
                guard let value = ProcessInfo.processInfo.environment["NYUTAG_UI_DELETE_ACCOUNT"], !value.isEmpty else { return }
                password = value
                await deleteAccount()
            }
            #endif
        }
    }

    private func deleteAccount() async {
        busy = true
        defer { busy = false }
        failure = nil
        do {
            try await session.deleteAccount(password: password)
            #if DEBUG
            print("ui-check: аккаунт удалён, фаза \(session.phase)")
            #endif
            dismiss()
        } catch .wrongPassword {
            failure = words(.wrongPassword)
        } catch .noNetwork {
            failure = words(.noNetwork)
        } catch {
            failure = words(.deleteAccountFailed)
        }
    }
}

/// Значок «Избранного» вместо буквы: закладка на голубом.
struct SavedPillow: View {
    var size: CGFloat = 52

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.34, style: .continuous)
            .fill(Theme.sky.gradient)
            .overlay {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
