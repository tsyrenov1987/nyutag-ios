// Нютаг. Сообщества: свои сверху, ниже каталог сервера с поиском. Сообщество — пространство Matrix (`m.space`),
// внутри него группы. Открытое пускает сразу, закрытое — по заявке, которую одобряет админ.

import NyutagCore
import SwiftUI

/// Что знаем о сообществе: из каталога или, для своего, из списка комнат.
struct Community: Hashable, Identifiable {
    let id: String
    let name: String
    var topic: String?
    var members: Int?
    var joinRule: String?
    var avatarURL: String?

    init(_ room: PublicRoom) {
        id = room.roomID
        name = room.name ?? room.canonicalAlias ?? ""
        topic = room.topic
        members = room.numJoinedMembers
        joinRule = room.joinRule
        avatarURL = room.avatarURL?.description
    }

    init(_ line: ChatLine) {
        id = line.id
        name = line.title
        avatarURL = line.avatarURL
    }

    var isClosed: Bool { joinRule == "knock" }
}

/// Куда ведёт навигация вкладки: в сообщество или в чат группы.
enum CommunityRoute: Hashable {
    case community(Community)
    case chat(String)
}

struct CommunitiesView: View {
    @Environment(Words.self) private var words
    @Environment(AppSession.self) private var session
    @State private var path: [CommunityRoute] = []
    @State private var search = ""
    @State private var catalog: [PublicRoom]?
    @State private var failed = false
    @State private var creating = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                let mine = session.communities.filter(matches)
                if !mine.isEmpty {
                    Section(words(.communitiesMine)) {
                        ForEach(mine) { line in
                            let known = catalog?.first { $0.roomID == line.id }
                            NavigationLink(value: CommunityRoute.community(known.map(Community.init) ?? Community(line))) {
                                CommunityRow(community: known.map(Community.init) ?? Community(line))
                            }
                        }
                    }
                }
                let others = (catalog ?? []).filter { room in !session.communities.contains { $0.id == room.roomID } }
                Section(words(.communitiesAll)) {
                    if others.isEmpty {
                        if failed {
                            Text(words(.communitiesFailed)).foregroundStyle(Theme.quiet)
                        } else if catalog == nil {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text(words(.communitiesEmpty)).foregroundStyle(Theme.quiet)
                        }
                    }
                    ForEach(others, id: \.roomID) { room in
                        NavigationLink(value: CommunityRoute.community(Community(room))) {
                            CommunityRow(community: Community(room))
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.milk.ignoresSafeArea())
            .navigationTitle(words(.communities))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: words(.communitiesSearch))
            .refreshable { await load() }
            .task(id: search) {
                // Поиск идёт на сервер: ждём паузы в наборе, чтобы не дёргать каталог на каждую букву.
                if !search.isEmpty { try? await Task.sleep(for: .milliseconds(400)) }
                // Сразу после запуска связь с ядром может ещё подниматься: повторяем, пока каталог не придёт.
                for pause in [0, 2, 4, 8, 15] {
                    if pause > 0 { try? await Task.sleep(for: .seconds(pause)) }
                    guard !Task.isCancelled else { return }
                    await load()
                    if !failed { return }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(words(.communityNew), systemImage: "plus") { creating = true }
                        .accessibilityIdentifier("community-new")
                }
            }
            .sheet(isPresented: $creating) {
                NewCommunityView { community in
                    path.append(.community(community))
                    Task { await load() }
                }
            }
            .navigationDestination(for: CommunityRoute.self) { route in
                switch route {
                case .community(let community): CommunityView(community: community, path: $path)
                case .chat(let roomID): ChatView(roomID: roomID)
                }
            }
        }
        #if DEBUG
        .task {
            // SIMCTL_CHILD_NYUTAG_UI_COMMUNITY=имя — открыть сообщество из каталога для самопроверки.
            guard let wanted = ProcessInfo.processInfo.environment["NYUTAG_UI_COMMUNITY"] else { return }
            while catalog == nil { try? await Task.sleep(for: .milliseconds(300)) }
            print("ui-check: сообществ в каталоге \(catalog?.count ?? -1), своих \(session.communities.count)")
            if let room = catalog?.first(where: { ($0.name ?? "").localizedCaseInsensitiveContains(wanted) }) {
                path = [.community(Community(room))]
            }
        }
        #endif
    }

    private func matches(_ line: ChatLine) -> Bool {
        search.isEmpty || line.title.localizedCaseInsensitiveContains(search)
    }

    private func load() async {
        let found = await session.findCommunities(search)
        failed = found == nil
        if let found { catalog = found.sorted { $0.numJoinedMembers > $1.numJoinedMembers } }
    }
}

struct CommunityRow: View {
    @Environment(Words.self) private var words
    let community: Community

    var body: some View {
        HStack(spacing: 12) {
            Pillow(seed: community.id, title: community.name.isEmpty ? "·" : community.name, size: 44,
                   avatar: community.avatarURL)
            VStack(alignment: .leading, spacing: 2) {
                Text(community.name.isEmpty ? words(.communities) : community.name)
                    .font(.headline).foregroundStyle(Theme.ink).lineLimit(1)
                let details = [community.members.map { words(.communityMembers, String($0)) },
                               community.isClosed ? words(.communityClosedBadge) : nil].compactMap(\.self)
                if !details.isEmpty {
                    Text(details.joined(separator: " · ")).font(.caption).foregroundStyle(Theme.quiet).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct CommunityView: View {
    @Environment(Words.self) private var words
    @Environment(AppSession.self) private var session
    let community: Community
    @Binding var path: [CommunityRoute]

    @State private var groups: [PublicRoom]?
    @State private var canAdd = false
    @State private var busy = false
    @State private var requested = false
    @State private var problem = false
    @State private var leaving = false
    @State private var naming = false
    @State private var groupName = ""
    @State private var people: [Person]?
    @State private var admins: Set<String> = []
    @State private var allPeople = false
    @State private var showing: String?

    private var joined: Bool { session.communities.contains { $0.id == community.id } }

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    Pillow(seed: community.id, title: community.name.isEmpty ? "·" : community.name, size: 76,
                           avatar: community.avatarURL)
                    Text(community.name).font(.title2.bold()).foregroundStyle(Theme.ink).multilineTextAlignment(.center)
                    if let topic = community.topic, !topic.isEmpty {
                        Text(topic).font(.subheadline).foregroundStyle(Theme.quiet).multilineTextAlignment(.center)
                    }
                    let badge = [community.joinRule.map { _ in words(community.isClosed ? .communityClosed : .communityOpen) },
                                 community.members.map { words(.communityMembers, String($0)) }].compactMap(\.self)
                    if !badge.isEmpty {
                        Text(badge.joined(separator: " · ")).font(.caption).foregroundStyle(Theme.quiet)
                    }
                    actions.padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            if requested {
                Section { Text(words(.communityRequested)).foregroundStyle(Theme.ink) }
            }
            if problem {
                Section { Text(words(.communityFailed)).foregroundStyle(Theme.quiet) }
            }
            if !joined, !requested {
                Section { Text(words(.communityJoinToWrite)).font(.footnote).foregroundStyle(Theme.quiet) }
            }
            Section {
                if let groups, groups.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(words(.communityNoGroups)).foregroundStyle(Theme.ink)
                        Text(words(joined && canAdd ? .communityNoGroupsAdmin : .communityNoGroupsHint)).font(.footnote).foregroundStyle(Theme.quiet)
                    }
                } else if groups == nil {
                    ProgressView().frame(maxWidth: .infinity)
                }
                ForEach(groups ?? [], id: \.roomID) { group in
                    Button { open(group.roomID) } label: {
                        HStack(spacing: 12) {
                            Pillow(seed: group.roomID, title: group.name ?? "·", size: 40,
                                   avatar: group.avatarURL?.description)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.name ?? words(.emptyChat)).foregroundStyle(Theme.ink).lineLimit(1)
                                Text(words(.communityMembers, String(group.numJoinedMembers)))
                                    .font(.caption).foregroundStyle(Theme.quiet)
                            }
                            Spacer(minLength: 4)
                            if joined {
                                Image(systemName: "bubble.left.and.bubble.right").foregroundStyle(Theme.sky)
                            }
                        }
                    }
                    .disabled(!joined || busy)
                }
                if joined, canAdd {
                    Button(words(.communityGroupNew), systemImage: "plus.bubble") { groupName = ""; naming = true }
                        .accessibilityIdentifier("community-group-new")
                }
            } header: {
                Text(words(.communityGroups))
            } footer: {
                if joined, let groups, !groups.isEmpty { Text(words(.communityGroupsHint)) }
            }
            if joined, let people, !people.isEmpty {
                Section(words(.communityPeople, String(people.count))) {
                    ForEach(allPeople ? people : Array(people.prefix(8))) { person in
                        Button { showing = person.userID } label: {
                            PersonRow(person: person, note: admins.contains(person.userID) ? words(.communityAdmin) : nil)
                        }
                    }
                    if people.count > 8, !allPeople {
                        Button(words(.communityShowAll)) { allPeople = true }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.milk.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .task(id: joined) { await loadGroups() }
        .refreshable { await loadGroups() }
        .sheet(isPresented: Binding { showing != nil } set: { if !$0 { showing = nil } }) {
            if let showing { PersonCard(userID: showing) }
        }
        .confirmationDialog(words(.communityLeaveAsk), isPresented: $leaving, titleVisibility: .visible) {
            Button(words(.communityLeave), role: .destructive) {
                Task {
                    busy = true
                    problem = !(await session.leaveCommunity(community.id))
                    busy = false
                }
            }
        }
        .alert(words(.communityGroupNew), isPresented: $naming) {
            TextField(words(.communityName), text: $groupName)
            Button(words(.cancel), role: .cancel) {}
            Button(words(.communityCreate)) { Task { await addGroup() } }
        }
    }

    @ViewBuilder private var actions: some View {
        if joined {
            Button { Task { await write() } } label: {
                Label(words(.communityWrite), systemImage: "square.and.pencil").frame(minWidth: 200)
            }
            .buttonStyle(.borderedProminent).tint(Theme.sky).controlSize(.large)
            .disabled(busy || (groups?.isEmpty == true && !canAdd))
            .accessibilityIdentifier("community-write")
            HStack(spacing: 12) {
                ShareLink(item: words(.communityInviteText, community.name)) {
                    Label(words(.communityInvite), systemImage: "person.badge.plus")
                }
                .buttonStyle(.bordered).tint(Theme.sky)
                Button(words(.communityLeave), systemImage: "rectangle.portrait.and.arrow.right") { leaving = true }
                    .buttonStyle(.bordered).tint(Theme.quiet)
                    .accessibilityIdentifier("community-leave")
            }
        } else if !requested {
            Button {
                Task { await join() }
            } label: {
                Text(words(community.isClosed ? .communityRequest : .communityJoin)).frame(minWidth: 160)
            }
            .buttonStyle(.borderedProminent).tint(Theme.sky)
            .disabled(busy)
            .accessibilityIdentifier("community-join")
        }
    }

    private func loadGroups() async {
        let found = await session.communityGroups(community.id)
        groups = found?.groups ?? groups ?? []
        canAdd = found?.canAdd ?? false
        guard joined, let found = await session.communityPeople(community.id) else { return }
        people = found.people
        admins = found.admins
    }

    /// Открывает общий чат — группу, где больше всего людей; если групп ещё нет, админ её создаёт.
    private func write() async {
        if let general = groups?.max(by: { $0.numJoinedMembers < $1.numJoinedMembers }) {
            open(general.roomID)
            return
        }
        guard canAdd else { return }
        busy = true
        defer { busy = false }
        guard let roomID = await session.createGroup(named: words(.communityGeneralChat), in: community.id) else {
            problem = true
            return
        }
        await loadGroups()
        path.append(.chat(roomID))
    }

    private func join() async {
        busy = true
        defer { busy = false }
        switch await session.joinCommunity(PublicRoom(roomID: community.id, joinRule: community.joinRule)) {
        case .joined: problem = false
        case .requested: requested = true; problem = false
        case .failed: problem = true
        }
        #if DEBUG
        print("ui-check: вступление в сообщество: \(joined ? "участник" : requested ? "заявка" : "не вышло")")
        #endif
    }

    private func open(_ roomID: String) {
        Task {
            busy = true
            defer { busy = false }
            if await session.joinGroup(roomID) { path.append(.chat(roomID)) } else { problem = true }
        }
    }

    private func addGroup() async {
        let name = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        busy = true
        defer { busy = false }
        guard let roomID = await session.createGroup(named: name, in: community.id) else { problem = true; return }
        #if DEBUG
        print("ui-check: группа сообщества создана")
        #endif
        await loadGroups()
        path.append(.chat(roomID))
    }
}

struct NewCommunityView: View {
    @Environment(Words.self) private var words
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let created: (Community) -> Void

    @State private var name = ""
    @State private var about = ""
    @State private var open = true
    @State private var busy = false
    @State private var problem = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(words(.communityName), text: $name)
                        .accessibilityIdentifier("community-name")
                    TextField(words(.communityAbout), text: $about, axis: .vertical).lineLimit(2...5)
                }
                Section {
                    Picker(selection: $open) {
                        Text(words(.communityOpen)).tag(true)
                        Text(words(.communityClosed)).tag(false)
                    } label: { EmptyView() }
                        .pickerStyle(.segmented)
                } footer: {
                    Text(words(open ? .communityOpenHint : .communityClosedHint))
                }
                if problem {
                    Section { Text(words(.communityFailed)).foregroundStyle(Theme.quiet) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.milk.ignoresSafeArea())
            .navigationTitle(words(.communityNew))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(words(.cancel)) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button(words(.communityCreate)) { Task { await create() } }
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("community-create")
                    }
                }
            }
        }
    }

    private func create() async {
        busy = true
        defer { busy = false }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = await session.createCommunity(name: title, about: about, open: open,
                                                   chatName: words(.communityGeneralChat)) else { problem = true; return }
        var community = Community(PublicRoom(roomID: id, name: title, topic: about, numJoinedMembers: 1,
                                             joinRule: open ? "public" : "knock", roomType: "m.space"))
        if about.isEmpty { community.topic = nil }
        dismiss()
        created(community)
    }
}
