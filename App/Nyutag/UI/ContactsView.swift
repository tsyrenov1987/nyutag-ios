// Нютаг. Вкладка «Контакты»: сверху те, кто в Нютаге (собеседники и найденные по номерам из книжки), ниже
// знакомые из книжки, которых можно позвать. Поиск ищет по имени, нику и номеру, а людей вне книжки спрашивает
// у сервера. Касание человека открывает личный чат, нового или уже существующего.

import Contacts
import NyutagCore
import SwiftUI
import UIKit

/// Телефонная книга: доступ и записи с номерами. Читаем в фоне, список держим только в памяти.
@MainActor @Observable
final class PhoneBook {
    private(set) var status = CNContactStore.authorizationStatus(for: .contacts)
    private(set) var entries: [BookEntry] = []

    var canRead: Bool { status == .authorized || status == .limited }

    func ask() async {
        _ = try? await CNContactStore().requestAccess(for: .contacts)
        status = CNContactStore.authorizationStatus(for: .contacts)
        await load()
    }

    func load() async {
        status = CNContactStore.authorizationStatus(for: .contacts)
        guard canRead else { return }
        entries = await Task.detached(priority: .userInitiated) { Self.read() }.value
    }

    private nonisolated static func read() -> [BookEntry] {
        let keys = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                    CNContactPhoneNumbersKey as CNKeyDescriptor, CNContactOrganizationNameKey as CNKeyDescriptor]
        var result: [BookEntry] = []
        try? CNContactStore().enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { contact, _ in
            let phones = contact.phoneNumbers.map(\.value.stringValue)
            guard !phones.isEmpty else { return }
            let name = CNContactFormatter.string(from: contact, style: .fullName) ?? contact.organizationName
            result.append(BookEntry(id: contact.identifier, name: name.isEmpty ? phones[0] : name, phones: phones))
        }
        return result
    }
}

struct ContactsView: View {
    @Environment(Words.self) private var words
    @Environment(AppSession.self) private var session
    @Environment(\.openURL) private var openURL
    @State private var book = PhoneBook()
    @State private var inNyutag: [Person] = []
    @State private var invite: [BookEntry] = []
    @State private var found: [Person] = []
    @State private var searched = ""
    @State private var query = ""
    @State private var opening: String?
    @State private var failed = false
    @State private var path: [String] = []
    /// Сверка номеров с сервером не чаще раза в десять минут: у сервера суточный предел.
    @State private var lookedUpAt: Date?
    @State private var matches: [String: String] = [:]
    @State private var inviting = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !book.canRead, query.isEmpty { access }
                people
                if query.trimmingCharacters(in: .whitespaces).count >= 2 { byName }
                if !shownInvite.isEmpty {
                    Section(words(.callToNyutag)) {
                        ForEach(shownInvite) { entry in InviteRow(entry: entry) }
                    }
                }
                if !query.isEmpty, shownPeople.isEmpty, shownFound.isEmpty, shownInvite.isEmpty, searched == query {
                    Text(words(.nobodyFound)).foregroundStyle(Theme.quiet).frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                    if isPhone {
                        Section {
                            Button { inviting = true } label: {
                                Label(words(.phoneNotInNyutag), systemImage: "person.badge.plus").foregroundStyle(Theme.sky)
                            }
                            .accessibilityIdentifier("contacts-invite-phone")
                        }
                        .listRowBackground(Theme.card)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.milk.ignoresSafeArea())
            .searchable(text: $query, prompt: words(.searchPeople))
            .navigationTitle(words(.contacts))
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { roomID in ChatView(roomID: roomID) }
            .alert(words(.cantOpenChat), isPresented: $failed) { Button(words(.done)) {} }
            .sheet(isPresented: $inviting) { InviteView() }
            .task { await reload() }
            .refreshable { lookedUpAt = nil; await reload() }
            .onChange(of: session.revision) { Task { await reload() } }
            .task(id: query) { await search() }
            #if DEBUG
            .task { await debugHooks() }
            #endif
        }
    }

    // MARK: Разделы

    private var access: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text(words(.bookTitle)).font(.headline).foregroundStyle(Theme.ink)
                if book.status == .notDetermined {
                    Text(words(.bookLead)).font(.subheadline).foregroundStyle(Theme.quiet)
                    BigButton(title: words(.bookAllow), busy: false, enabled: true, id: "contacts-allow") {
                        Task { await book.ask(); lookedUpAt = nil; await reload() }
                    }
                } else {
                    Text(words(.bookDenied)).font(.subheadline).foregroundStyle(Theme.quiet)
                    Button(words(.openSettings)) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    .foregroundStyle(Theme.sky)
                }
            }
            .padding(.vertical, 6)
        }
        .listRowBackground(Theme.card)
    }

    @ViewBuilder private var people: some View {
        if !shownPeople.isEmpty {
            Section(words(.inNyutag)) {
                ForEach(shownPeople) { person in personButton(person) }
            }
        } else if query.isEmpty {
            Text(words(.peopleEmpty)).font(.subheadline).foregroundStyle(Theme.quiet)
                .frame(maxWidth: .infinity).multilineTextAlignment(.center)
                .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder private var byName: some View {
        if !shownFound.isEmpty {
            Section(words(.foundByName)) {
                ForEach(shownFound) { person in personButton(person) }
            }
        }
    }

    private func personButton(_ person: Person) -> some View {
        Button { Task { await write(to: person) } } label: {
            PersonRow(person: person, busy: opening == person.userID)
        }
        .buttonStyle(.plain)
        .disabled(opening != nil)
        .listRowBackground(Theme.card)
        .accessibilityIdentifier("person-\(person.userID)")
    }

    // MARK: Отбор

    private var shownPeople: [Person] {
        inNyutag.filter { People.matches(query, name: $0.name, userID: $0.userID, phones: $0.phone.map { [$0] } ?? []) }
    }

    /// Найденные сервером, кроме тех, кто уже показан выше.
    private var shownFound: [Person] {
        let shown = Set(shownPeople.map(\.userID))
        return found.filter { !shown.contains($0.userID) }
    }

    private var isPhone: Bool {
        query.count(where: \.isNumber) >= 10 && People.phoneKey(query) != nil
    }

    private var shownInvite: [BookEntry] {
        invite.filter { People.matches(query, name: $0.name, phones: $0.phones) }
    }

    // MARK: Дела

    private func reload() async {
        await book.load()
        let known = await session.knownPeople()
        if book.canRead, lookedUpAt.map({ Date.now.timeIntervalSince($0) > 600 }) ?? true {
            lookedUpAt = .now
            matches = await session.lookup(phones: People.uniquePhones(book.entries))
        }
        let merged = People.merge(book: book.canRead ? book.entries : [], matches: matches, known: known)
        if merged.inNyutag != inNyutag { inNyutag = merged.inNyutag }
        if merged.invite != invite { invite = merged.invite }
    }

    private func search() async {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard term.count >= 2 else { found = []; searched = query; return }
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        let result = await session.searchPeople(term.hasPrefix("@") ? String(term.dropFirst()) : term)
        guard !Task.isCancelled else { return }
        found = result
        searched = query
        #if DEBUG
        print("ui-check: поиск «\(term)»: в Нютаге \(shownPeople.count), по имени \(shownFound.count), позвать \(shownInvite.count)")
        #endif
    }

    private func write(to person: Person) async {
        opening = person.userID
        defer { opening = nil }
        if let roomID = await session.openDirect(with: person.userID) {
            path.append(roomID)
        } else {
            failed = true
        }
    }

    #if DEBUG
    /// Проверка на телефоне: NYUTAG_UI_FIND набирает поиск, NYUTAG_UI_WRITE открывает чат с первым найденным.
    private func debugHooks() async {
        let env = ProcessInfo.processInfo.environment
        print("ui-check: контакты, доступ к книжке \(book.status.rawValue), в Нютаге \(inNyutag.count), позвать \(invite.count)")
        guard let term = env["NYUTAG_UI_FIND"] else { return }
        query = term
        guard env["NYUTAG_UI_WRITE"] != nil else { return }
        for _ in 0..<40 where searched != term { try? await Task.sleep(for: .milliseconds(250)) }
        if let person = shownPeople.first ?? shownFound.first { await write(to: person) }
    }
    #endif
}

struct PersonRow: View {
    let person: Person
    var busy = false
    /// Пометка справа, например «админ».
    var note: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Pillow(seed: person.userID, title: person.name, size: 44, avatar: person.avatarURL)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name).font(.body.weight(.medium)).foregroundStyle(Theme.ink).lineLimit(1)
                Text("@" + ChatDigest.localpart(person.userID)).font(.footnote).foregroundStyle(Theme.quiet).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let note { Text(note).font(.caption).foregroundStyle(Theme.quiet) }
            if busy { ProgressView() }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}

struct InviteRow: View {
    @Environment(Words.self) private var words
    let entry: BookEntry

    var body: some View {
        HStack(spacing: 12) {
            Pillow(seed: entry.id, title: entry.name, size: 44).saturation(0.2)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).foregroundStyle(Theme.ink).lineLimit(1)
                Text(entry.phones[0]).font(.footnote).foregroundStyle(Theme.quiet).lineLimit(1)
            }
            Spacer(minLength: 4)
            ShareLink(item: words(.inviteText)) {
                Text(words(.inviteShort)).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.sky)
            }
            .buttonStyle(.borderless)
        }
        .listRowBackground(Theme.card)
    }
}
