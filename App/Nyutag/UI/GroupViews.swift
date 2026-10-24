// Нютаг. Группы из списка чатов: создать (название + кого позвать из тех, с кем уже есть переписка),
// «О группе» (шапка с фото и описанием, участники с ролями, добавить, без звука, выйти) и «Управление»
// (название, фото, описание, кто пишет, заявки, ссылка, заблокированные) — общее для групп и сообществ. Зовут тех, с кем уже есть общие чаты,
// а не из телефонной книги: в группу зовут тех, кто уже в Нютаге.

import NyutagCore
import PhotosUI
import SwiftUI

/// Список людей с галочками: для новой группы и для добавления участников.
struct PeoplePicker: View {
    @Environment(Words.self) private var words
    @Environment(AppSession.self) private var session
    @Binding var chosen: Set<String>
    /// Кого не показывать: уже в группе.
    var hidden: Set<String> = []
    @State private var people: [Person]?
    @State private var query = ""

    private var shown: [Person] {
        (people ?? []).filter { !hidden.contains($0.userID) }
            .filter { query.isEmpty || People.matches(query, name: $0.name, userID: $0.userID, phones: []) }
    }

    var body: some View {
        Group {
            if let people, people.allSatisfy({ hidden.contains($0.userID) }) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(words(.groupNobody)).foregroundStyle(Theme.ink)
                    Text(words(.groupWhoHint)).font(.footnote).foregroundStyle(Theme.quiet)
                }
            } else if people == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
            ForEach(shown) { person in
                Button {
                    if chosen.contains(person.userID) { chosen.remove(person.userID) } else { chosen.insert(person.userID) }
                } label: {
                    HStack(spacing: 12) {
                        PersonRow(person: person)
                        Image(systemName: chosen.contains(person.userID) ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(chosen.contains(person.userID) ? Theme.sky : Theme.quiet)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("pick-\(ChatDigest.localpart(person.userID))")
            }
        }
        .task { people = await session.acquaintances() }
    }
}

/// Новая группа: название и участники.
struct GroupCreateView: View {
    @Environment(Words.self) private var words
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let onCreated: (String) -> Void
    @State private var name = ""
    @State private var chosen: Set<String> = []
    @State private var busy = false
    @State private var failed = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField(words(.groupName), text: $name)
                        .accessibilityIdentifier("group-name")
                }
                Section(words(.groupWho)) {
                    PeoplePicker(chosen: $chosen)
                }
                if failed {
                    Section { Text(words(.groupFailed)).foregroundStyle(Theme.quiet) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.milk.ignoresSafeArea())
            .navigationTitle(words(.groupNew))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(words(.cancel)) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button(words(.groupCreate)) { create() }
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || chosen.isEmpty)
                            .accessibilityIdentifier("group-create")
                    }
                }
            }
            #if DEBUG
            .task { await prefillForScreenshots() }
            #endif
        }
    }

    private func create() {
        busy = true
        failed = false
        Task {
            if let roomID = await session.createGroup(name: name, members: chosen.sorted()) {
                dismiss()
                onCreated(roomID)
            } else {
                failed = true
            }
            busy = false
        }
    }

    #if DEBUG
    /// `NYUTAG_UI_GROUP=<название>:<ник1,ник2>` — заполнить и создать.
    private func prefillForScreenshots() async {
        guard let spec = ProcessInfo.processInfo.environment["NYUTAG_UI_GROUP"] else { return }
        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        name = parts[0]
        let wanted = Set((parts.count > 1 ? parts[1] : "").split(separator: ",").map(String.init))
        let people = await session.acquaintances()
        chosen = Set(people.map(\.userID).filter { wanted.contains(ChatDigest.localpart($0)) })
        print("ui-check: новая группа «\(name)», выбрано \(chosen.count) из \(people.count)")
        guard !chosen.isEmpty, ProcessInfo.processInfo.environment["NYUTAG_UI_GROUP_STOP"] == nil else { return }
        try? await Task.sleep(for: .seconds(1))
        create()
    }
    #endif
}

/// О группе: шапка как в Telegram, круглые кнопки, участники с ролями; админу — «Изменить».
struct GroupInfoView: View {
    @Environment(Words.self) private var words
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let roomID: String
    /// Группа покинута: чат закрывается.
    var onLeft: () -> Void = {}
    /// Пока права и состав идут с сервера — участники из своей базы (без себя).
    @State private var local: [Person]?
    @State private var facts: AppSession.RoomFacts?
    @State private var adding = false
    @State private var chosen: Set<String> = []
    @State private var busy = false
    @State private var addFailed = false
    @State private var askLeave = false
    @State private var leaveFailed = false
    @State private var target: Person?
    @State private var managing = false
    @State private var viewingPhoto = false

    private var line: ChatLine? { session.lines.first { $0.id == roomID } }
    private var me: String { session.me ?? "" }
    private var title: String { facts.map(\.name).flatMap { $0.isEmpty ? nil : $0 } ?? line?.title ?? "" }
    private var photo: String? { facts?.avatarURL ?? line?.avatarURL }
    private var people: [Person]? {
        guard let facts else { return local }
        return facts.roster.joined.sorted { facts.powers.level(of: $0.userID) > facts.powers.level(of: $1.userID) }
    }
    private var count: Int? { facts.map(\.roster.joined.count) ?? local.map { $0.count + 1 } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    header.frame(maxWidth: .infinity).listRowBackground(Color.clear)
                }
                Section(words(.groupMembers)) {
                    if facts?.powers.canInvite(me) ?? true {
                        Button { adding = true } label: {
                            Label { Text(words(.groupAdd)).foregroundStyle(Theme.ink) } icon: {
                                Image(systemName: "person.badge.plus").foregroundStyle(Theme.sky)
                            }
                        }
                        .accessibilityIdentifier("group-add")
                    }
                    if addFailed {
                        Text(words(.groupAddFailed)).font(.footnote).foregroundStyle(Theme.quiet)
                    }
                    if people == nil {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                    ForEach(people ?? []) { person in
                        Button { target = person } label: {
                            PersonRow(person: person, note: RoleNote.text(facts?.powers, person.userID, words))
                        }
                        .buttonStyle(.plain)
                    }
                }
                if leaveFailed {
                    Section { Text(words(.chatLeaveFailed)).font(.footnote).foregroundStyle(Theme.quiet) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.milk.ignoresSafeArea())
            .navigationTitle(words(.groupInfo))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let facts, RoomAdminView.canManage(facts.powers, me) {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(words(.editAction)) { managing = true }.accessibilityIdentifier("group-manage")
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button(words(.done)) { dismiss() } }
            }
            .sheet(isPresented: $adding, onDismiss: { chosen = [] }) { addSheet }
            .sheet(isPresented: $managing) { RoomAdminView(roomID: roomID, community: false) { await loadFacts() } }
            .fullScreenCover(isPresented: $viewingPhoto) { if let photo { AvatarViewer(url: photo, title: title) } }
            .modifier(MemberActions(target: $target, roomID: roomID, powers: facts?.powers, community: false) { await loadFacts() })
            .confirmationDialog(words(.chatLeave), isPresented: $askLeave, titleVisibility: .visible) {
                Button(words(.chatLeave), role: .destructive) { leave() }
                Button(words(.cancel), role: .cancel) {}
            } message: { Text(words(.chatLeaveHint)) }
            .task { await loadFacts() }
            .task(id: session.revision) {
                let fresh = await session.members(of: roomID)
                if fresh != local { local = fresh }
                #if DEBUG
                if !Self.printed {
                    Self.printed = true
                    print("ui-check: о группе «\(line?.title ?? "")», участников кроме меня \(fresh.count): \(fresh.map(\.name).joined(separator: ", "))")
                }
                #endif
            }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Button { if photo != nil { viewingPhoto = true } } label: {
                Pillow(seed: roomID, title: title.isEmpty ? "·" : title, size: 96, avatar: photo)
            }
            .buttonStyle(.plain)
            Text(title).font(.title2.bold()).foregroundStyle(Theme.ink).multilineTextAlignment(.center)
            let details = [count.map { words(.communityMembers, String($0)) }, line?.community].compactMap(\.self)
            if !details.isEmpty {
                Text(details.joined(separator: " · ")).font(.caption).foregroundStyle(Theme.quiet).multilineTextAlignment(.center)
            }
            if let topic = facts?.topic, !topic.isEmpty {
                Text(topic).font(.subheadline).foregroundStyle(Theme.ink).multilineTextAlignment(.center).padding(.top, 2)
            }
            HStack(spacing: 10) {
                let quiet = session.isMuted(roomID)
                RoundAction(title: words(quiet ? .unmute : .mute), symbol: quiet ? "bell" : "bell.slash") {
                    Task { _ = await session.setMuted(roomID, !quiet) }
                }
                .accessibilityIdentifier("group-mute")
                if facts?.powers.canInvite(me) ?? true {
                    RoundAction(title: words(.communityInvite), symbol: "person.badge.plus") { adding = true }
                }
                RoundAction(title: words(.communityLeave), symbol: "rectangle.portrait.and.arrow.right", tint: Theme.quiet) {
                    askLeave = true
                }
                .accessibilityIdentifier("group-leave")
            }
            .padding(.top, 8)
        }
    }

    private var addSheet: some View {
        NavigationStack {
            List {
                Section(words(.groupWho)) {
                    PeoplePicker(chosen: $chosen, hidden: Set((people ?? []).map(\.userID)))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.milk.ignoresSafeArea())
            .navigationTitle(words(.groupAdd))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(words(.cancel)) { adding = false } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button(words(.groupAdd)) { add() }.disabled(chosen.isEmpty)
                    }
                }
            }
        }
    }

    private func loadFacts() async {
        if let fresh = await session.facts(roomID) { facts = fresh }
    }

    private func add() {
        busy = true
        Task {
            addFailed = !(await session.invite(chosen.sorted(), to: roomID))
            busy = false
            adding = false
            local = await session.members(of: roomID)
            await loadFacts()
        }
    }

    private func leave() {
        Task {
            if await session.leaveChat(roomID) {
                dismiss()
                onLeft()
            } else {
                leaveFailed = true
            }
        }
    }

    #if DEBUG
    nonisolated(unsafe) static var printed = false
    #endif
}

/// Круглая кнопка под шапкой: значок и подпись.
struct RoundAction: View {
    let title: String
    let symbol: String
    var tint: Color = Theme.sky
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.title3).frame(height: 26)
                Text(title).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity).padding(.vertical, 10)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// Пометка роли справа в списке участников.
enum RoleNote {
    @MainActor static func text(_ powers: RoomPowers?, _ userID: String, _ words: Words) -> String? {
        switch powers?.role(of: userID) {
        case .owner: words(.roleOwner)
        case .admin: words(.communityAdmin)
        case .moderator: words(.roleModerator)
        default: nil
        }
    }
}

/// Нажатие на участника: профиль, а если права позволяют — назначить или снять админа, удалить, заблокировать.
/// Ничего из этого нельзя — сразу профиль.
struct MemberActions: ViewModifier {
    @Environment(Words.self) private var words
    @Environment(AppSession.self) private var session
    @Binding var target: Person?
    let roomID: String
    let powers: RoomPowers?
    let community: Bool
    let changed: () async -> Void
    @State private var menu: Person?
    @State private var profile: String?
    @State private var banning: Person?
    @State private var failed = false

    private var me: String { session.me ?? "" }

    func body(content: Content) -> some View {
        content
            .onChange(of: target) {
                guard let person = target else { return }
                target = nil
                if hasActions(person) { menu = person } else { profile = person.userID }
            }
            .confirmationDialog(menu?.name ?? "", isPresented: Binding { menu != nil } set: { if !$0 { menu = nil } },
                                titleVisibility: .visible, presenting: menu) { person in
                Button(words(.profile)) { profile = person.userID }
                if let powers {
                    let role = powers.role(of: person.userID)
                    if role < .admin, powers.canSetLevel(me, person.userID, to: RoomPowers.admin) {
                        Button(words(.makeAdmin)) { run { await session.setLevel(person.userID, to: RoomPowers.admin, in: roomID) } }
                    }
                    if role == .admin || role == .moderator, powers.canSetLevel(me, person.userID, to: 0) {
                        Button(words(.removeAdmin)) { run { await session.setLevel(person.userID, to: 0, in: roomID) } }
                    }
                    if powers.canKick(me, person.userID) {
                        Button(words(community ? .removeFromCommunity : .removeFromGroup), role: .destructive) {
                            run { await session.remove(person.userID, from: roomID, community: community) }
                        }
                    }
                    if powers.canBan(me, person.userID) {
                        Button(words(.banMember), role: .destructive) { banning = person }
                    }
                }
                Button(words(.cancel), role: .cancel) {}
            }
            .confirmationDialog(banning.map { words(.banAsk, $0.name) } ?? "",
                                isPresented: Binding { banning != nil } set: { if !$0 { banning = nil } },
                                titleVisibility: .visible, presenting: banning) { person in
                Button(words(.banMember), role: .destructive) {
                    run { await session.ban(person.userID, in: roomID, community: community) }
                }
                Button(words(.cancel), role: .cancel) {}
            }
            .sheet(isPresented: Binding { profile != nil } set: { if !$0 { profile = nil } }) {
                if let profile { PersonCard(userID: profile) }
            }
            .alert(words(.cantDo), isPresented: $failed) { Button(words(.done)) {} }
    }

    private func hasActions(_ person: Person) -> Bool {
        guard let powers, person.userID != me else { return false }
        return powers.canKick(me, person.userID) || powers.canBan(me, person.userID)
            || powers.canSetLevel(me, person.userID, to: RoomPowers.admin) || powers.canSetLevel(me, person.userID, to: 0)
    }

    private func run(_ work: @escaping () async -> Bool) {
        Task {
            if await work() { await changed() } else { failed = true }
        }
    }
}

/// Управление группой или сообществом: оформление, кто пишет или кто входит, заявки, ссылка, заблокированные.
struct RoomAdminView: View {
    @Environment(Words.self) private var words
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let roomID: String
    let community: Bool
    var changed: () async -> Void = {}

    @State private var facts: AppSession.RoomFacts?
    @State private var name = ""
    @State private var topic = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var photoBusy = false
    @State private var busy = false
    @State private var failed = false
    @State private var unavailable = false

    /// Что-то из управления доступно: показывать кнопку «Изменить» или «Управление».
    static func canManage(_ powers: RoomPowers, _ me: String) -> Bool {
        [EventType.name, EventType.avatar, EventType.topic, EventType.powerLevels, "m.room.join_rules"]
            .contains { powers.canSetState(me, type: $0) } || powers.canBan(me, "")
    }

    private var me: String { session.me ?? "" }
    private func can(_ type: String) -> Bool { facts?.powers.canSetState(me, type: type) ?? false }
    private var link: URL { CommunityLink.web(roomID) }
    private var dirty: Bool { facts.map { $0.name != name || $0.topic != topic } ?? false }

    var body: some View {
        NavigationStack {
            Form {
                if let facts { content(facts) } else if unavailable {
                    Text(words(.cantDo)).foregroundStyle(Theme.quiet)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.milk.ignoresSafeArea())
            .navigationTitle(words(.manage))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(words(dirty ? .cancel : .done)) { dismiss() } }
                if dirty {
                    ToolbarItem(placement: .confirmationAction) {
                        if busy { ProgressView() } else {
                            Button(words(.save)) { Task { await save() } }
                                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                .accessibilityIdentifier("room-save")
                        }
                    }
                }
            }
            // Новая заявка или участник приходят с синхронизацией: перечитываем, набранное название не трогаем.
            .task(id: session.revision) { await load() }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    let data = try? await item.loadTransferable(type: Data.self)
                    photoItem = nil
                    await setPhoto(data)
                }
            }
            .alert(words(.cantDo), isPresented: $failed) { Button(words(.done)) {} }
        }
    }

    @ViewBuilder private func content(_ facts: AppSession.RoomFacts) -> some View {
        Section {
            VStack(spacing: 10) {
                Pillow(seed: roomID, title: name.isEmpty ? "·" : name, size: 88, avatar: facts.avatarURL)
                    .overlay { if photoBusy { ProgressView() } }
                if can(EventType.avatar) {
                    HStack(spacing: 16) {
                        PhotosPicker(selection: $photoItem, matching: .images) { Text(words(.roomPhotoChange)) }
                            .accessibilityIdentifier("room-photo")
                        if facts.avatarURL != nil {
                            Button(words(.roomPhotoRemove), role: .destructive) { Task { await setPhoto(nil) } }
                        }
                    }
                    .font(.subheadline).buttonStyle(.borderless).disabled(photoBusy)
                }
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
        }
        Section {
            TextField(words(.communityName), text: $name)
                .disabled(!can(EventType.name))
                .accessibilityIdentifier("room-name")
            TextField(words(community ? .communityAbout : .groupAbout), text: $topic, axis: .vertical)
                .lineLimit(2...6)
                .disabled(!can(EventType.topic))
                .accessibilityIdentifier("room-topic")
        }
        if community {
            Section {
                Picker(selection: Binding { facts.isClosed } set: { closed in change { await session.setClosed(closed, community: roomID) } }) {
                    Text(words(.communityOpen)).tag(false)
                    Text(words(.communityClosed)).tag(true)
                } label: { EmptyView() }
                    .pickerStyle(.segmented)
                    .disabled(!can("m.room.join_rules"))
            } header: { Text(words(.access)) } footer: {
                Text(words(facts.isClosed ? .communityClosedHint : .communityOpenHint))
            }
            Section {
                ShareLink(item: link, message: Text(words(.communityInviteText, name, link.absoluteString))) {
                    Label(words(.communityInvite), systemImage: "square.and.arrow.up")
                }
                Button(words(.copyLink), systemImage: "doc.on.doc") { UIPasteboard.general.url = link }
            } header: { Text(words(.inviteLink)) } footer: { Text(words(.inviteLinkHint)) }
            if facts.isClosed || !facts.roster.knocking.isEmpty {
                Section(words(.requests, String(facts.roster.knocking.count))) {
                    if facts.roster.knocking.isEmpty {
                        Text(words(.requestsNone)).foregroundStyle(Theme.quiet)
                    }
                    ForEach(facts.roster.knocking) { person in
                        HStack(spacing: 8) {
                            PersonRow(person: person)
                            if facts.powers.canInvite(me) {
                                Button { change { await session.answerRequest(person.userID, in: roomID, accept: false) } } label: {
                                    Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(Theme.quiet)
                                }
                                .accessibilityLabel(words(.decline))
                                Button { change { await session.answerRequest(person.userID, in: roomID, accept: true) } } label: {
                                    Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(Theme.sky)
                                }
                                .accessibilityLabel(words(.approve))
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        } else {
            Section {
                Toggle(isOn: Binding { facts.powers.onlyAdminsWrite } set: { on in change { await session.setOnlyAdminsWrite(on, in: roomID) } }) {
                    Label(words(.onlyAdminsWrite), systemImage: "megaphone")
                }
                .tint(Theme.sky)
                .disabled(!can(EventType.powerLevels))
                .accessibilityIdentifier("room-only-admins")
            } footer: { Text(words(.onlyAdminsWriteHint)) }
        }
        if !facts.roster.banned.isEmpty {
            Section(words(.bannedSection)) {
                ForEach(facts.roster.banned) { person in
                    HStack(spacing: 8) {
                        PersonRow(person: person)
                        if facts.powers.canBan(me, person.userID) {
                            Button(words(.unban)) { change { await session.unban(person.userID, in: roomID, community: community) } }
                                .font(.subheadline).buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
    }

    private func load() async {
        guard let fresh = await session.facts(roomID) else { unavailable = facts == nil; return }
        if facts == nil || !dirty {
            name = fresh.name
            topic = fresh.topic
        }
        facts = fresh
    }

    private func change(_ work: @escaping () async -> Bool) {
        Task {
            if !(await work()) { failed = true }
            await load()
            await changed()
        }
    }

    private func setPhoto(_ picked: Data?) async {
        photoBusy = true
        defer { photoBusy = false }
        var jpeg: Data?
        if let picked {
            jpeg = await Task.detached(priority: .userInitiated) { ImageMemory.squareJPEG(picked, side: 512) }.value
            guard jpeg != nil else { failed = true; return }
        }
        if !(await session.setRoomPhoto(jpeg, in: roomID)) { failed = true }
        await load()
        await changed()
    }

    private func save() async {
        guard let facts else { return }
        busy = true
        defer { busy = false }
        var ok = true
        if name != facts.name { ok = await session.setRoomName(name, in: roomID) && ok }
        if topic != facts.topic { ok = await session.setRoomTopic(topic, in: roomID) && ok }
        await changed()
        if ok { dismiss() } else { failed = true; await load() }
    }
}
