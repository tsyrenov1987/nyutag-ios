// Нютаг. Группы из списка чатов: создать (название + кого позвать из тех, с кем уже есть переписка),
// «О группе» (участники с фото, добавить, без звука, выйти). Зовут тех, с кем уже есть общие чаты,
// а не из телефонной книги: в группу зовут тех, кто уже в Нютаге.

import NyutagCore
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

/// О группе: участники, добавить, без звука, выйти.
struct GroupInfoView: View {
    @Environment(Words.self) private var words
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let roomID: String
    /// Группа покинута: чат закрывается.
    var onLeft: () -> Void = {}
    @State private var members: [Person]?
    @State private var adding = false
    @State private var chosen: Set<String> = []
    @State private var busy = false
    @State private var addFailed = false
    @State private var askLeave = false
    @State private var leaveFailed = false
    @State private var showing: String?

    private var line: ChatLine? { session.lines.first { $0.id == roomID } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 10) {
                        Pillow(seed: roomID, title: line?.title ?? "·", size: 76, avatar: line?.avatarURL)
                        Text(line?.title ?? "").font(.title2.bold()).foregroundStyle(Theme.ink).multilineTextAlignment(.center)
                        if let members {
                            Text(words(.communityMembers, String(members.count + 1))).font(.caption).foregroundStyle(Theme.quiet)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
                Section {
                    Toggle(isOn: Binding { session.isMuted(roomID) } set: { quiet in Task { _ = await session.setMuted(roomID, quiet) } }) {
                        Label(words(.mute), systemImage: "bell.slash")
                    }
                    .tint(Theme.sky)
                    .accessibilityIdentifier("group-mute")
                }
                Section(words(.groupMembers)) {
                    Button { adding = true } label: {
                        Label { Text(words(.groupAdd)).foregroundStyle(Theme.ink) } icon: {
                            Image(systemName: "person.badge.plus").foregroundStyle(Theme.sky)
                        }
                    }
                    .accessibilityIdentifier("group-add")
                    if addFailed {
                        Text(words(.groupAddFailed)).font(.footnote).foregroundStyle(Theme.quiet)
                    }
                    if members == nil {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                    ForEach(members ?? []) { person in
                        Button { showing = person.userID } label: { PersonRow(person: person) }
                            .buttonStyle(.plain)
                    }
                }
                Section {
                    Button(role: .destructive) { askLeave = true } label: {
                        Label(words(.chatLeave), systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .accessibilityIdentifier("group-leave")
                    if leaveFailed {
                        Text(words(.chatLeaveFailed)).font(.footnote).foregroundStyle(Theme.quiet)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.milk.ignoresSafeArea())
            .navigationTitle(words(.groupInfo))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(words(.done)) { dismiss() } }
            }
            .sheet(isPresented: $adding, onDismiss: { chosen = [] }) { addSheet }
            .sheet(isPresented: Binding { showing != nil } set: { if !$0 { showing = nil } }) {
                if let showing { PersonCard(userID: showing) }
            }
            .confirmationDialog(words(.chatLeave), isPresented: $askLeave, titleVisibility: .visible) {
                Button(words(.chatLeave), role: .destructive) { leave() }
                Button(words(.cancel), role: .cancel) {}
            } message: { Text(words(.chatLeaveHint)) }
            .task(id: session.revision) {
                let fresh = await session.members(of: roomID)
                if fresh != members { members = fresh }
                #if DEBUG
                if !Self.printed {
                    Self.printed = true
                    print("ui-check: о группе «\(line?.title ?? "")», участников кроме меня \(fresh.count): \(fresh.map(\.name).joined(separator: ", "))")
                }
                #endif
            }
        }
    }

    private var addSheet: some View {
        NavigationStack {
            List {
                Section(words(.groupWho)) {
                    PeoplePicker(chosen: $chosen, hidden: Set((members ?? []).map(\.userID)))
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

    private func add() {
        busy = true
        Task {
            addFailed = !(await session.invite(chosen.sorted(), to: roomID))
            busy = false
            adding = false
            members = await session.members(of: roomID)
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
