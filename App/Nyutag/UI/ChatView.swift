// Нютаг. Экран чата: лента снизу вверх, пузыри-«листья» (острый угол у верхнего края со стороны автора),
// свои синие, чужие белые, оба контрастны к молочному фону. Служебное и дни — на плашках с подложкой.
// Отправка сразу показывает реплику с часиками; не ушла — подпись «нажмите, чтобы повторить».
// Долгое нажатие на пузырь: реакции строкой сверху, ответ, копия, а у своих — правка и удаление.
// Скрепка у поля ввода шлёт снимок из галереи или файл; касание вложения открывает его на весь экран.

import NyutagCore
import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @Environment(Words.self) private var words
    @Environment(AppSession.self) private var session
    let roomID: String

    @State private var items: [FeedItem] = []
    /// Карточка собеседника личного чата.
    @State private var partner: String?
    @State private var showingPartner = false
    @State private var showingInfo = false
    @State private var askLeave = false
    @Environment(\.dismiss) private var dismiss
    @State private var choosingWallpaper = false
    @State private var limit = 80
    @State private var hasOlder = true
    @State private var loadingOlder = false
    @State private var outbox: [Outgoing] = []
    @State private var draft = ""
    @State private var replyTo: FeedItem?
    @State private var editing: FeedItem?
    @State private var deleting: FeedItem?
    @State private var reporting: FeedItem?
    @State private var reportSent = false
    @State private var failed = false
    @State private var typingSentAt: Date?
    @State private var lastMarked: String?
    @State private var pickingPhoto = false
    @State private var pickingFile = false
    @State private var photoItem: PhotosPickerItem?
    @State private var previewURL: URL?
    @State private var openingID: String?
    /// Исчезающее фото: следующий снимок из галереи уйдёт с меткой; открытое сейчас — во весь экран.
    @State private var pickingOnce = false
    /// Ролик пережимается перед отправкой: вместо скрепки крутилка.
    @State private var preparingVideo = false
    @State private var videoTooBig = false
    /// Текст, который откладываем: открыто окно выбора времени.
    @State private var scheduling: String?
    @State private var scheduleDate = Date.now.addingTimeInterval(3600)
    @State private var schedulePast = false
    @State private var showingScheduled = false
    @State private var viewingOnce: OnceShot?
    struct OnceShot: Identifiable {
        let id: String
        let image: UIImage
    }
    /// Автоудаление: правило из базы, а пока сервер не прислал наше новое — то, что мы поставили.
    @State private var rule = AutoDelete()
    @State private var settingRule: AutoDelete?
    @State private var ruleFailed = false
    /// Свои истёкшие, которые уже попросили сервер удалить.
    @State private var tidied: Set<String> = []
    @FocusState private var typing: Bool

    struct Outgoing: Identifiable, Equatable {
        let id: String
        let text: String
        let replyTo: FeedItem?
        /// Вложение вместо текста; `text` тогда — имя файла.
        var file: OutgoingFile?
        var preview: UIImage?
        var eventID: String?
        var failed = false

        static func == (a: Outgoing, b: Outgoing) -> Bool { a.id == b.id && a.eventID == b.eventID && a.failed == b.failed }
    }

    /// Звонить можно, когда в чате ровно один собеседник.
    @State private var callKind = AppSession.CallKind.none

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
                    FeedRow(item: item, showsAuthor: isGroup && startsRun(item, after: previous),
                            opening: openingID == item.id) { action in
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
        .background(WallpaperBackground(roomID: roomID).ignoresSafeArea())
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
        .alert(words(.videoTooBig), isPresented: $videoTooBig) { Button(words(.done)) {} }
        .alert(words(.autoDeleteError), isPresented: $ruleFailed) { Button(words(.done)) {} }
        .alert(words(.schedulePast), isPresented: $schedulePast) { Button(words(.done)) {} }
        .sheet(isPresented: Binding { scheduling != nil } set: { if !$0 { scheduling = nil } }) { schedulePicker }
        .sheet(isPresented: $showingScheduled) { scheduledList }
        .sheet(isPresented: $showingPartner) { if let partner { PersonCard(userID: partner) } }
        .sheet(isPresented: $showingInfo) { GroupInfoView(roomID: roomID) { dismiss() } }
        .confirmationDialog(words(.chatLeave), isPresented: $askLeave, titleVisibility: .visible) {
            Button(words(.chatLeave), role: .destructive) { leave() }
            Button(words(.cancel), role: .cancel) {}
        } message: { Text(words(.chatLeaveHint)) }
        .sheet(item: $reporting) { item in ReportSheet(item: item, roomID: roomID) { reportSent = true } }
        .alert(words(.reportSent), isPresented: $reportSent) { Button(words(.done)) {} }
        .sheet(isPresented: $choosingWallpaper) { WallpaperPicker(roomID: roomID) }
        .task {
            partner = await session.partner(in: roomID)
            #if DEBUG
            if ProcessInfo.processInfo.environment["NYUTAG_UI_SHEET"] == "partner" {
                print("ui-check: собеседник \(partner.map(ChatDigest.localpart) ?? "не найден")")
                showingPartner = partner != nil
            }
            if ProcessInfo.processInfo.environment["NYUTAG_UI_GROUP_INFO"] != nil { showingInfo = true }
            if let quiet = ProcessInfo.processInfo.environment["NYUTAG_UI_MUTE"] {
                _ = await session.setMuted(roomID, quiet == "on")
                print("ui-check: в списке без звука \(session.isMuted(roomID))")
            }
            // Один раз за запуск: после выхода хук OPEN_CHAT может открыть другой чат с похожим названием.
            if ProcessInfo.processInfo.environment["NYUTAG_UI_LEAVE"] != nil, !Self.leftOnce {
                Self.leftOnce = true
                try? await Task.sleep(for: .seconds(2))
                leave()
            }
            #endif
        }
        // Исчезающее — только снимок; обычный выбор — снимки и ролики.
        .photosPicker(isPresented: $pickingPhoto, selection: $photoItem, matching: pickingOnce ? .images : .any(of: [.images, .videos]))
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { Task { await attachFile(url) } }
        }
        .onChange(of: photoItem) {
            guard let picked = photoItem else { return }
            photoItem = nil
            let types = picked.supportedContentTypes
            if types.contains(where: { $0.conforms(to: .movie) }), !types.contains(where: { $0.conforms(to: .image) }) {
                Task { await attachVideo(picked) }
            } else {
                Task { await attachPhoto(picked) }
            }
        }
        .quickLookPreview($previewURL)
        .fullScreenCover(item: $viewingOnce, onDismiss: {}) { shot in
            ViewOnceViewer(image: shot.image) { closeOnce(shot) }
        }
        .onChange(of: previewURL) { if previewURL == nil { OpenedFiles.clear() } }
        .onChange(of: draft) { noteTyping() }
        .onAppear { PushDoor.shared.openRoom = roomID }
        .onDisappear {
            stopTyping()
            if PushDoor.shared.openRoom == roomID { PushDoor.shared.openRoom = nil }
        }
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            if callKind != .none {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(words(callKind == .group ? .callGroupAction : .callAction), systemImage: "phone") {
                        Task { await session.startCall(in: roomID) }
                    }
                }
            }
            if callKind == .direct {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(words(.callVideoAction), systemImage: "video") {
                        Task { await session.startCall(in: roomID, video: true) }
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if partner != nil {
                        Button(words(.profile), systemImage: "person.crop.circle") { showingPartner = true }
                    }
                    if line?.isDirect == false, roomID != session.savedRoom {
                        Button(words(.groupInfo), systemImage: "person.2") { showingInfo = true }
                    }
                    Button(words(.wallpaperForChat), systemImage: "paintpalette") { choosingWallpaper = true }
                    Picker(selection: Binding { rule.choice } set: { setRule($0) }) {
                        ForEach(AutoDelete.choices, id: \.self) { Text(ruleName($0)).tag($0) }
                    } label: {
                        Label(words(.autoDelete), systemImage: "timer")
                        Text(rule.isOn ? ruleName(rule.choice) : words(.autoDeleteHint))
                    }
                    .pickerStyle(.menu)
                    if roomID != session.savedRoom {
                        if session.isMuted(roomID) {
                            Button(words(.unmute), systemImage: "bell") { Task { await session.setMuted(roomID, false) } }
                        } else {
                            Button(words(.mute), systemImage: "bell.slash") { Task { await session.setMuted(roomID, true) } }
                        }
                        Divider()
                        Button(words(.chatLeave), systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                            askLeave = true
                        }
                    }
                } label: {
                    Group {
                        if roomID == session.savedRoom {
                            SavedPillow(size: 32)
                        } else {
                            Pillow(seed: roomID, title: line?.title ?? "·", size: 32, avatar: line?.avatarURL)
                        }
                    }
                        .overlay(alignment: .bottomTrailing) {
                            if rule.isOn {
                                Image(systemName: "timer").font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Theme.onGold)
                                    .padding(2).background(Theme.gold, in: Circle())
                            }
                        }
                }
                .accessibilityIdentifier("chat-menu")
            }
        }
        .task(id: roomID) { callKind = await session.callKind(roomID) }
        .task(id: rule.nextExpiry(items)) {
            // Ближайшая реплика истекает — пересобрать ленту в этот момент.
            guard let at = rule.nextExpiry(items) else { return }
            try? await Task.sleep(for: .seconds(max(1, at.timeIntervalSinceNow + 0.5)))
            if !Task.isCancelled { await reload() }
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
            if !queued.isEmpty {
                Button { showingScheduled = true } label: {
                    Label(words(.scheduleBanner, "\(queued.count)"), systemImage: "clock")
                        .font(.footnote.weight(.semibold)).foregroundStyle(Theme.sky)
                        .frame(maxWidth: .infinity).padding(.top, 8)
                }
                .accessibilityIdentifier("chat-scheduled")
            }
            if let editing {
                banner(title: words(.editing), text: summary(editing.body), symbol: "pencil") {
                    self.editing = nil
                    draft = ""
                }
            } else if let replyTo {
                banner(title: replyTo.senderName, text: summary(replyTo.body), symbol: nil) { self.replyTo = nil }
            }
            HStack(alignment: .bottom, spacing: 8) {
                if editing == nil {
                    Menu {
                        Button(words(.photoAction), systemImage: "photo.on.rectangle") { pickingOnce = false; pickingPhoto = true }
                        // В открытом чате ключ ушёл бы рядом с фото: исчезающее — только под шифрованием.
                        if line?.isEncrypted == true {
                            Button(words(.viewOnceAction), systemImage: "flame") { pickingOnce = true; pickingPhoto = true }
                        }
                        Button(words(.fileAction), systemImage: "doc") { pickingFile = true }
                    } label: {
                        Group {
                            if preparingVideo {
                                ProgressView().tint(Theme.quiet)
                            } else {
                                Image(systemName: "paperclip").font(.title3).foregroundStyle(Theme.quiet)
                            }
                        }
                        .frame(width: 36, height: 40)
                    }
                    .disabled(preparingVideo)
                    .accessibilityLabel(words(.attach))
                    .accessibilityIdentifier("chat-attach")
                }
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
                .contextMenu {
                    if editing == nil, canSend {
                        Button(words(.scheduleAction), systemImage: "clock") { askSchedule() }
                    }
                }
                .accessibilityLabel(words(.send))
                .accessibilityIdentifier("chat-send")
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .background(Theme.card)
    }

    /// Отложенные этого чата, ближайшие первыми.
    private var queued: [ScheduledMessage] {
        guard let me = session.me else { return [] }
        return session.scheduled.inRoom(roomID, account: me)
    }

    private var schedulePicker: some View {
        NavigationStack {
            Form {
                DatePicker(words(.scheduleAction), selection: $scheduleDate, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.graphical)
                    .environment(\.locale, (words.lang ?? .ru).locale)
                    .environment(\.calendar, pickerCalendar)
                Section { Text(scheduling ?? "").lineLimit(4) } footer: { Text(words(.scheduleHint)) }
            }
            .navigationTitle(words(.scheduleAction))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(words(.cancel)) { scheduling = nil } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(words(.done), action: confirmSchedule).accessibilityIdentifier("schedule-confirm")
                }
            }
        }
        .presentationDetents([.large])
    }

    /// По-русски и по-бурятски неделя с понедельника, по-английски — как в настройках телефона.
    private var pickerCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = (words.lang ?? .ru).locale
        calendar.firstWeekday = words.lang == .en ? Calendar.current.firstWeekday : 2
        return calendar
    }

    private var scheduledList: some View {
        NavigationStack {
            List {
                ForEach(queued) { message in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(message.body).lineLimit(4)
                        Text(words(.scheduleAt, message.date.formatted(.dateTime.locale((words.lang ?? .ru).locale)
                            .day().month().hour().minute())))
                            .font(.caption).foregroundStyle(Theme.quiet)
                    }
                    .swipeActions {
                        Button(words(.deleteAction), role: .destructive) { session.dropScheduled(message.id) }
                        Button(words(.scheduleSendNow)) { session.sendScheduledNow(message.id) }.tint(Theme.sky)
                    }
                    .contextMenu {
                        Button(words(.scheduleSendNow), systemImage: "paperplane") { session.sendScheduledNow(message.id) }
                        Button(words(.deleteAction), systemImage: "trash", role: .destructive) { session.dropScheduled(message.id) }
                    }
                }
            }
            .navigationTitle(words(.scheduleTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(words(.done)) { showingScheduled = false } } }
            .onChange(of: queued.isEmpty) { if queued.isEmpty { showingScheduled = false } }
        }
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
        let stored = await session.autoDelete(roomID)
        if stored == settingRule { settingRule = nil }
        let current = settingRule ?? stored
        if current != rule { rule = current }
        let all = await session.feed(roomID, limit: limit)
        let fresh = current.visible(all)
        if fresh != items { items = fresh }
        let expired = current.ownToDelete(all).filter { !tidied.contains($0) }
        if !expired.isEmpty {
            tidied.formUnion(expired)
            for id in expired { _ = await session.delete(id, in: roomID) }
            #if DEBUG
            print("ui-check: автоудаление убрало свои \(expired.count)")
            #endif
        }
        // Создание чата видно — раньше ничего нет.
        if case .notice(.created) = items.first?.body { hasOlder = false }
        outbox.removeAll { pending in pending.eventID.map { id in items.contains { $0.id == id } } ?? false }
        if let last = items.last(where: { !$0.isMine && !$0.isNotice }), last.id != lastMarked {
            lastMarked = last.id
            await session.markRead(roomID, upTo: last.id)
        }
    }

    private func setRule(_ ttl: Int) {
        guard ttl != rule.choice else { return }
        Task {
            guard let fresh = await session.setAutoDelete(ttl, in: roomID) else { ruleFailed = true; return }
            settingRule = fresh
            rule = fresh
            #if DEBUG
            print("ui-check: автоудаление \(fresh.ttl) с")
            #endif
        }
    }

    private func ruleName(_ ttl: Int) -> String {
        switch ttl {
        case 0: words(.autoDeleteOff)
        case AutoDelete.day: words(.autoDeleteDay)
        case AutoDelete.week: words(.autoDeleteWeek)
        case AutoDelete.month: words(.autoDeleteMonth)
        default: "\(ttl) с"
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
        case .open:
            open(item)
        case .report:
            reporting = item
        }
    }

    /// Вложение на весь экран: расшифрованная копия во временной папке, пока открыт просмотр.
    private func open(_ item: FeedItem) {
        guard let attachment = item.attachment, openingID == nil else { return }
        if attachment.viewOnce {
            openOnce(item, attachment)
            return
        }
        openingID = item.id
        Task {
            defer { openingID = nil }
            var name = attachment.name
            if URL(filePath: name).pathExtension.isEmpty,
               let ext = attachment.mimetype.flatMap({ UTType(mimeType: $0) })?.preferredFilenameExtension {
                name += "." + ext
            }
            if let data = await session.attachmentData(attachment, preview: false), let url = OpenedFiles.write(data, name: name) {
                previewURL = url
            } else {
                failed = true
            }
            #if DEBUG
            print("ui-check: вложение \(previewURL == nil ? "не открылось" : "открыто")")
            #endif
        }
    }

    /// Исчезающее фото открывается один раз и только у получателя; после просмотра реплику удаляем.
    private func openOnce(_ item: FeedItem, _ attachment: Attachment) {
        guard !item.isMine, !ViewOnceSeen.shared.contains(item.id) else { return }
        openingID = item.id
        Task {
            defer { openingID = nil }
            guard let data = await session.attachmentData(attachment, preview: false), let image = UIImage(data: data) else {
                #if DEBUG
                print("ui-check: исчезающее фото не скачалось")
                #endif
                failed = true
                return
            }
            ViewOnceSeen.shared.mark(item.id)
            let shot = OnceShot(id: item.id, image: image)
            viewingOnce = shot
            #if DEBUG
            print("ui-check: исчезающее фото открыто, \(Int(image.size.width))×\(Int(image.size.height))")
            if ProcessInfo.processInfo.environment["NYUTAG_UI_OPEN"] != nil {
                try? await Task.sleep(for: .seconds(4))
                closeOnce(shot)
            }
            #endif
        }
    }

    private func closeOnce(_ shot: OnceShot) {
        viewingOnce = nil
        Task {
            let removed = await session.delete(shot.id, in: roomID)
            #if DEBUG
            print("ui-check: исчезающее фото \(removed ? "удалено" : "осталось на сервере (нет прав), но больше не откроется")")
            #endif
        }
    }

    /// Имя файла по времени: «20261021T132705».
    private var stamp: String {
        Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).filter { $0.isNumber || $0 == "T" }
    }

    /// Ролик из галереи: копия во временной папке → пережатие до 720p → в очередь. Слишком большой — отдельное сообщение.
    private func attachVideo(_ picked: PhotosPickerItem) async {
        preparingVideo = true
        defer { preparingVideo = false }
        guard let movie = try? await picked.loadTransferable(type: PickedMovie.self) else { failed = true; return }
        await attachVideo(at: movie.url)
    }

    private func attachVideo(at url: URL) async {
        defer { try? FileManager.default.removeItem(at: url) }
        let name = "video-" + stamp
        guard let file = await OutgoingFile.video(at: url, name: name) else {
            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            // Пережатый ролик заметно меньше исходного: не вышло с большим файлом — скорее всего не влез.
            if bytes > OutgoingFile.videoLimit { videoTooBig = true } else { failed = true }
            return
        }
        #if DEBUG
        print("ui-check: видео \(file.width ?? 0)×\(file.height ?? 0), \(file.duration ?? 0) мс, \(file.data.count / 1024) КБ, миниатюра \(file.thumbnail?.count ?? 0) Б")
        #endif
        queue(file)
    }

    private func attachPhoto(_ picked: PhotosPickerItem) async {
        let name = "photo-" + stamp
        guard let data = try? await picked.loadTransferable(type: Data.self),
              var file = await Task.detached(priority: .userInitiated, operation: { OutgoingFile.photo(data, name: name) }).value
        else { failed = true; return }
        file.viewOnce = pickingOnce
        pickingOnce = false
        queue(file)
    }

    private func attachFile(_ url: URL) async {
        guard let file = await Task.detached(priority: .userInitiated, operation: { OutgoingFile.file(at: url) }).value else {
            failed = true
            return
        }
        queue(file)
    }

    /// Вложение сразу видно в ленте с часиками, как и текст.
    private func queue(_ file: OutgoingFile) {
        let source = file.mimetype.hasPrefix("image/") ? file.data : file.thumbnail
        let preview = source.flatMap { ImageMemory.downsample($0, maxPixels: 900) }
        let pending = Outgoing(id: TransactionID.make(), text: file.name, replyTo: nil, file: file, preview: preview)
        outbox.append(pending)
        deliver(pending)
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

    private func askSchedule() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        scheduleDate = Date.now.addingTimeInterval(3600)
        scheduling = text
    }

    private func confirmSchedule() {
        guard let text = scheduling else { return }
        guard scheduleDate > .now else { schedulePast = true; return }
        session.schedule(text, in: roomID, at: scheduleDate)
        scheduling = nil
        draft = ""
        replyTo = nil
        stopTyping()
    }

    private func retry(_ pending: Outgoing) {
        guard pending.failed, let index = outbox.firstIndex(of: pending) else { return }
        outbox[index].failed = false
        deliver(outbox[index])
    }

    private func deliver(_ pending: Outgoing) {
        Task {
            let eventID: String? = if let file = pending.file {
                await session.sendAttachment(file, to: roomID, transactionID: pending.id)
            } else {
                await session.send(pending.text, to: roomID, replyTo: pending.replyTo?.id, transactionID: pending.id)
            }
            // Своя картинка уже есть в памяти: обратно с сервера её не качаем.
            if let eventID, let preview = pending.preview { ImageMemory.put(preview, eventID) }
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
        // NYUTAG_UI_AUTODELETE=секунды (0 — выключить): таймер ставится один раз за запуск.
        if !Self.ruledForScreenshots, let ttl = env["NYUTAG_UI_AUTODELETE"].flatMap(Int.init) {
            Self.ruledForScreenshots = true
            Task {
                if let fresh = await session.setAutoDelete(ttl, in: roomID) { settingRule = fresh; rule = fresh }
                print("ui-check: автоудаление \(rule.ttl) с, в ленте \(items.count)")
            }
        }
        if let kind = env["NYUTAG_UI_ATTACH"] { attachForScreenshots(kind) }
        // NYUTAG_UI_SHEET=schedule — окно выбора времени для текста NYUTAG_UI_SEND, scheduled — очередь чата.
        if !Self.sheetForScreenshots, let sheet = env["NYUTAG_UI_SHEET"], sheet == "wallpaper" {
            Self.sheetForScreenshots = true
            choosingWallpaper = true
        }
        if !Self.sheetForScreenshots, let sheet = env["NYUTAG_UI_SHEET"], sheet != "partner" {
            Self.sheetForScreenshots = true
            if sheet == "schedule" { draft = env["NYUTAG_UI_SEND"] ?? "Проверка"; askSchedule() } else { showingScheduled = true }
            print("ui-check: открыто окно \(sheet)")
        }
        // NYUTAG_UI_OPEN=once — ждать чужое исчезающее фото и открыть его.
        let once = env["NYUTAG_UI_OPEN"] == "once"
        if env["NYUTAG_UI_OPEN"] != nil, !Self.openedForScreenshots,
           let last = items.last(where: { $0.attachment != nil && (!once || ($0.attachment?.viewOnce == true && !$0.isMine)) }) {
            Self.openedForScreenshots = true
            open(last)
        }
        guard !Self.sentForScreenshots, let text = env["NYUTAG_UI_SEND"] else { return }
        Self.sentForScreenshots = true
        // NYUTAG_UI_SCHEDULE=секунды — не сразу, а отложенным.
        if let delay = env["NYUTAG_UI_SCHEDULE"].flatMap(Double.init) {
            session.schedule(text, in: roomID, at: .now.addingTimeInterval(delay))
            print("ui-check: отложено на \(Int(delay)) с, в очереди чата \(queued.count)")
            return
        }
        draft = text
        sendDraft()
        print("ui-check: отправка ушла в очередь")
    }

    private static var attachedForScreenshots = false
    private static var ruledForScreenshots = false
    private static var openedForScreenshots = false
    private static var sheetForScreenshots = false

    /// NYUTAG_UI_ATTACH: `photo` — нарисованный снимок 1600×1200 (`once` — он же исчезающим), `file` — небольшой
    /// текстовый файл, `video` — нарисованный ролик на 2 секунды через тот же путь, что и из галереи.
    private func attachForScreenshots(_ kind: String) {
        guard !Self.attachedForScreenshots else { return }
        Self.attachedForScreenshots = true
        if kind == "video" {
            Task {
                preparingVideo = true
                defer { preparingVideo = false }
                guard let url = await OutgoingFile.drawnVideo() else { print("ui-check: ролик не нарисовался"); return }
                await attachVideo(at: url)
            }
            return
        }
        if kind == "file" {
            queue(OutgoingFile(data: Data("Нютаг β: проверка вложения\n".utf8), name: "proverka.txt", mimetype: "text/plain"))
            return
        }
        let size = CGSize(width: 1600, height: 1200)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let drawn = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let colors = [UIColor(Theme.sky).cgColor, UIColor(Theme.gold).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: nil) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
            ("Нютаг β" as NSString).draw(at: CGPoint(x: 120, y: 480),
                                          withAttributes: [.font: UIFont.boldSystemFont(ofSize: 180), .foregroundColor: UIColor.white])
        }
        guard let jpeg = drawn.jpegData(compressionQuality: 0.9), var file = OutgoingFile.photo(jpeg, name: "proverka") else { return }
        file.viewOnce = kind == "once"
        queue(file)
    }

    /// NYUTAG_UI_ACT над своей последней текстовой репликой, по одному шагу за запуск:
    /// `react:👍`, `edit:новый текст`, `delete`.
    private static var actedForScreenshots = false

    private func actForScreenshots(_ step: String) {
        guard !Self.actedForScreenshots else { return }
        let (verb, rest) = (step.prefix { $0 != ":" }, step.drop { $0 != ":" }.dropFirst())
        // report/block/unblock — над чужой репликой, остальное — над своей.
        let foreign = ["report", "block", "unblock"].contains(verb)
        guard let target = items.last(where: { foreign ? $0.canReport : $0.canEdit }) else { return }
        Self.actedForScreenshots = true
        print("ui-check: действие \(verb) над \(target.id.prefix(8))… от \(target.sender), в ленте \(items.count)")
        switch verb {
        case "react": act(.react(String(rest)), on: target)
        case "edit":
            act(.edit, on: target)
            draft = String(rest)
            sendDraft()
        case "delete": run { await session.delete(target.id, in: roomID) }
        case "report": run { await session.report(target.id, in: roomID, reason: String(rest)) }
        case "block", "unblock":
            // «unblock:@кто:сервер» — конкретный человек, без него — автор последней чужой реплики.
            let who = rest.isEmpty ? target.sender : String(rest)
            run {
                let done = await session.setBlocked(who, verb == "block")
                print("ui-check: блок \(who) \(session.isBlocked(who)), в ленте \(items.count)")
                return done
            }
        default: break
        }
    }
    #endif

    // MARK: Помощники

    private func leave() {
        Task {
            if await session.leaveChat(roomID) { dismiss() } else { failed = true }
        }
    }

    #if DEBUG
    nonisolated(unsafe) static var leftOnce = false
    #endif

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
    enum Action { case reply, edit, delete, react(String), open, report }

    /// Быстрые реакции в меню, по порядку.
    static let quick = ["👍", "❤️", "😂", "😮", "😢", "🙏"]

    @Environment(Words.self) private var words
    let item: FeedItem
    let showsAuthor: Bool
    var opening = false
    let perform: (Action) -> Void

    var body: some View {
        if case .notice(let notice) = item.body {
            Plate(text: NoticeText.make(notice, words: words))
        } else {
            HStack(alignment: .bottom, spacing: 0) {
                if item.isMine { Spacer(minLength: 56) }
                VStack(alignment: item.isMine ? .trailing : .leading, spacing: 4) {
                    Bubble(item: item, showsAuthor: showsAuthor, opening: opening) { perform(.open) }
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
        if item.canReport {
            Button(words(.reportAction), systemImage: "exclamationmark.bubble", role: .destructive) { perform(.report) }
        }
    }
}

struct Bubble: View {
    @Environment(Words.self) private var words
    let item: FeedItem
    let showsAuthor: Bool
    var opening = false
    var open: () -> Void = {}

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
            VStack(alignment: .leading, spacing: 6) {
                if let attachment = item.attachment, attachment.viewOnce {
                    Button(action: open) {
                        ViewOnceChip(mine: item.isMine, seen: ViewOnceSeen.shared.contains(item.id), ink: ink, soft: soft, busy: opening)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("attachment-\(item.id)")
                } else if let attachment = item.attachment, attachment.isImage {
                    AttachmentImage(key: item.id, attachment: attachment)
                        .overlay { if opening { ProgressView().tint(.white) } }
                        .onTapGesture(perform: open)
                        .accessibilityIdentifier("attachment-\(item.id)")
                } else if let attachment = item.attachment, attachment.isVideo {
                    AttachmentImage(key: item.id, attachment: attachment)
                        .overlay { VideoBadge(duration: attachment.duration, busy: opening) }
                        .onTapGesture(perform: open)
                        .accessibilityIdentifier("attachment-\(item.id)")
                } else if let attachment = item.attachment {
                    Button(action: open) {
                        FileChip(name: attachment.name, size: attachment.size, ink: ink, soft: soft, busy: opening)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("attachment-\(item.id)")
                } else {
                    Label(ChatRow.label(kind, words: words), systemImage: ChatRow.symbol(kind)).foregroundStyle(ink)
                }
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
                    if let preview = pending.preview, let file = pending.file {
                        Image(uiImage: preview).resizable().scaledToFill()
                            .frame(width: AttachmentImage.width,
                                   height: AttachmentImage.height(pixels: (file.width, file.height), image: preview))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay { if file.mimetype.hasPrefix("video/") { VideoBadge(duration: file.duration) } }
                    } else if let file = pending.file {
                        FileChip(name: file.name, size: file.data.count, ink: .white, soft: .white.opacity(0.75))
                    } else {
                        Text(pending.text).foregroundStyle(.white)
                    }
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

/// Жалоба администратору на чужую реплику, с кнопкой «пожаловаться и заблокировать» автора.
struct ReportSheet: View {
    @Environment(Words.self) private var words
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let item: FeedItem
    let roomID: String
    let onSent: () -> Void
    @State private var reason = ""
    @State private var busy = false
    @State private var failed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(words(.reportLead)).foregroundStyle(Theme.ink)
                    TextField(words(.reportReason), text: $reason, axis: .vertical)
                        .lineLimit(3...6)
                        .padding(16)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .accessibilityIdentifier("report-reason")
                    BigButton(title: words(.send), busy: busy, enabled: !busy, id: "report-send") {
                        Task { await send(block: false) }
                    }
                    Button(words(.reportAndBlock), role: .destructive) { Task { await send(block: true) } }
                        .font(.callout.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .disabled(busy)
                        .accessibilityIdentifier("report-block")
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.milk.ignoresSafeArea())
            .navigationTitle(words(.reportTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(words(.cancel)) { dismiss() } }
            }
            .alert(words(.cantDo), isPresented: $failed) { Button(words(.done)) {} }
        }
    }

    private func send(block: Bool) async {
        busy = true
        defer { busy = false }
        let text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard await session.report(item.id, in: roomID, reason: text.isEmpty ? words(.reportAction) : text) else {
            failed = true
            return
        }
        if block { _ = await session.setBlocked(item.sender, true) }
        dismiss()
        onSent()
    }
}
