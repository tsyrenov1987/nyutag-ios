// Нютаг. Главный экран: вкладки Чаты | Контакты | Сообщества, заголовок по центру, свой аватар слева открывает меню.
// Строка чата — карточка: аватар-подушка, имя, время, последняя реплика, галочки у своей, золотой счётчик.

import NyutagCore
import SwiftUI

struct HomeView: View {
    @Environment(Words.self) private var words
    @Environment(AppSession.self) private var session
    @State private var tab = 0

    var body: some View {
        // Свёрнутый звонок — над вкладками, а не поверх: заголовки и списки уходят под него, не просвечивая.
        VStack(spacing: 6) {
            if session.calls.showsStrip { CallStrip() }
            TabView(selection: $tab) {
                Tab(words(.chats), systemImage: "bubble.left.and.bubble.right", value: 0) { ChatListView() }
                Tab(words(.contacts), systemImage: "person.2", value: 1) { ContactsView() }
                Tab(words(.communities), systemImage: "circle.hexagongrid", value: 2) { CommunitiesView() }
            }
        }
        .background(Theme.milk.ignoresSafeArea())
        .onChange(of: PushDoor.shared.tappedRoom) { if PushDoor.shared.tappedRoom != nil { tab = 0 } }
        .animation(.smooth, value: session.calls.showsStrip)
        .fullScreenCover(isPresented: .constant(session.calls.current != nil && !session.calls.folded)) { CallView() }
        .sheet(isPresented: Bindable(session).showDeviceCheck, onDismiss: { Task { await session.closeDeviceCheck() } }) {
            DeviceCheckView()
        }
        #if DEBUG
        .onAppear {
            if ProcessInfo.processInfo.environment["NYUTAG_UI_CONTACTS"] != nil { tab = 1 }
            if ProcessInfo.processInfo.environment["NYUTAG_UI_COMMUNITY"] != nil { tab = 2 }
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
    @State private var keySheet = false
    /// Открытая папка; `nil` — «Все».
    @State private var folder: String?
    @State private var naming: FolderNaming?
    @State private var folderName = ""
    @State private var deleting: ChatFolder?

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                if !session.layout.folders.isEmpty {
                    FolderBar(selected: $folder, naming: $naming, deleting: $deleting)
                        .padding(.top, 2)
                }
                if session.historyLocked {
                    LockedHistoryCard { keySheet = true }
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                }
                if session.needsOtherDevice {
                    UnconfirmedSignInCard { session.showDeviceCheck = true }
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button(words(.savedMessages), systemImage: "bookmark") { openSaved() }
                        .accessibilityIdentifier("saved-messages")
                }
            }
            .navigationDestination(for: String.self) { roomID in ChatView(roomID: roomID) }
            .sheet(isPresented: $menu) { MeMenu(onSaved: openSaved) }
            .sheet(isPresented: $keySheet) { HistoryKeyView(canRelock: session.canRelockHistory) }
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
                guard env["NYUTAG_UI_INVITE"] != nil || env["NYUTAG_UI_ABOUT"] != nil || env["NYUTAG_UI_DONATE"] != nil else { return }
                while session.lines.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
                menu = true
            }
            .task {
                guard ProcessInfo.processInfo.environment["NYUTAG_UI_SAVED"] != nil else { return }
                while session.lines.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
                openSaved()
            }
            .onChange(of: session.historyLocked, initial: true) {
                if session.historyLocked, ProcessInfo.processInfo.environment["NYUTAG_UI_TRY_KEY"] != nil { keySheet = true }
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
              let line = session.lines.first(where: { $0.title.localizedCaseInsensitiveContains(wanted) }) else { return }
        path = [line.id]
        print("ui-check: открыт чат, событий в списке \(session.lines.count)")
    }
    #endif
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
                Pillow(seed: line.id, title: line.title.isEmpty ? "·" : line.title)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
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
                    Spacer(minLength: 4)
                    if line.lastIsMine { Ticks(delivery: line.delivery) }
                    if line.lastTS > 0 {
                        Text(Self.time(line.lastTS, words: words))
                            .font(.caption).monospacedDigit()
                            .foregroundStyle(line.unread > 0 ? Theme.gold : Theme.quiet)
                    }
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
    @State private var inviting = false
    @State private var choosingWallpaper = false
    @State private var donating = false
    @State private var editingProfile = false
    let onSaved: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        ProfileEditView()
                    } label: {
                        HStack(spacing: 14) {
                            Pillow(seed: session.me ?? "", title: ChatDigest.localpart(session.me ?? ""), size: 64)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ChatDigest.localpart(session.me ?? "")).font(.title3.bold())
                                Text(session.me ?? "").font(.footnote).foregroundStyle(Theme.quiet)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .accessibilityIdentifier("menu-profile")
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
            .sheet(isPresented: $inviting) { InviteView() }
            .sheet(isPresented: $choosingWallpaper) { WallpaperPicker() }
            .sheet(isPresented: $donating) { DonateView() }
            #if DEBUG
            .onAppear {
                if ProcessInfo.processInfo.environment["NYUTAG_UI_INVITE"] != nil { inviting = true }
                if ProcessInfo.processInfo.environment["NYUTAG_UI_DONATE"] != nil { donating = true }
                if ProcessInfo.processInfo.environment["NYUTAG_UI_ABOUT"] != nil { editingProfile = true }
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
