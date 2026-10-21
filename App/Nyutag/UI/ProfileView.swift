// Нютаг. Профиль: своё имя и «о себе» (тоонто нютаг, уг гарбал, восточный год) — правка, чужое — карточка.

import NyutagCore
import SwiftUI

struct ProfileEditView: View {
    @Environment(Words.self) private var words
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var old: Profile?
    @State private var name = ""
    @State private var about = ProfileAbout()
    @State private var busy = false
    @State private var failed = false
    /// Свой номер: по нему находят те, у кого он в книжке. nil — ещё не знаем, указан ли.
    @State private var hasPhone: Bool?
    @State private var phone = ""

    var body: some View {
        Form {
            Section(words(.name)) {
                TextField(words(.name), text: $name)
                    .textContentType(.name)
                    .accessibilityIdentifier("profile-name")
            }
            Section(words(.profileAbout)) {
                TextField(words(.profileAboutPlaceholder), text: $about.about, axis: .vertical)
                    .lineLimit(2...6)
                    .accessibilityIdentifier("profile-about")
            }
            Section(words(.profileToonto)) {
                TextField(words(.profileToontoPlaceholder), text: $about.toonto)
            }
            Section(words(.profileUg)) {
                TextField(words(.profileUgPlaceholder), text: $about.ug)
            }
            Section {
                TextField(words(hasPhone == true ? .myPhoneChange : .myPhonePlaceholder), text: $phone)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .accessibilityIdentifier("profile-phone")
            } header: {
                Text(words(.myPhone))
            } footer: {
                Text(words(hasPhone == true ? .myPhoneSet : .myPhoneHint))
            }
            Section {
                NavigationLink {
                    EastYearPicker(key: $about.eastYear)
                } label: {
                    LabeledContent(words(.profileEastYear),
                                   value: EastYear(key: about.eastYear).map(words.eastYear) ?? words(.profileEastYearNone))
                }
                .accessibilityIdentifier("profile-east-year")
            } footer: {
                if failed { Text(words(.profileSaveFailed)).foregroundStyle(.red) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.milk.ignoresSafeArea())
        .navigationTitle(words(.profile))
        .navigationBarTitleDisplayMode(.inline)
        .disabled(old == nil)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(words(.save)) { Task { await save() } }
                    .disabled(old == nil || busy)
                    .accessibilityIdentifier("profile-save")
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard old == nil, let me = session.me, let profile = await session.profile(of: me) else { return }
        old = profile
        name = profile.displayName ?? ChatDigest.localpart(me)
        about = ProfileAbout(profile: profile)
        hasPhone = await session.hasPhone()
        #if DEBUG
        if let text = ProcessInfo.processInfo.environment["NYUTAG_UI_ABOUT"] {
            about.about = text
            about.eastYear = EastYear(year: 1987).key
            await save()
        }
        #endif
    }

    private func save() async {
        guard let old else { return }
        busy = true
        defer { busy = false }
        failed = !(await session.saveProfile(name: name, about: about, was: old))
        let number = phone.trimmingCharacters(in: .whitespaces)
        if !failed, !number.isEmpty {
            let saved = People.phoneKey(number) == nil ? false : await session.setPhone(number)
            if !saved {
                failed = true
            } else {
                hasPhone = true
                phone = ""
            }
        }
        #if DEBUG
        print("ui-check: профиль \(failed ? "не сохранён" : "сохранён")")
        #endif
        if !failed { dismiss() }
    }
}

/// Год выбирают по числу, на сервер уходит стихия и животное.
struct EastYearPicker: View {
    @Environment(Words.self) private var words
    @Environment(\.dismiss) private var dismiss
    @Binding var key: String

    var body: some View {
        let now = Calendar.current.component(.year, from: Date())
        List {
            Section {
                row(words(.profileEastYearNone), chosen: key.isEmpty) { key = "" }
            } footer: {
                Text(words(.profileEastYearHint))
            }
            Section {
                ForEach((1925...now).reversed(), id: \.self) { year in
                    let east = EastYear(year: year)
                    row("\(year) · \(words.eastYear(east))", chosen: east.key == key) { key = east.key }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.milk.ignoresSafeArea())
        .navigationTitle(words(.profileEastYear))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ title: String, chosen: Bool, pick: @escaping () -> Void) -> some View {
        Button {
            pick()
            dismiss()
        } label: {
            HStack {
                Text(title).foregroundStyle(Theme.ink)
                Spacer()
                if chosen { Image(systemName: "checkmark").foregroundStyle(Theme.sky) }
            }
        }
    }
}

/// Карточка собеседника: имя, адрес и заполненные поля «о себе».
struct PersonCard: View {
    @Environment(Words.self) private var words
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let userID: String
    @State private var profile: Profile?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 8) {
                        Pillow(seed: userID, title: profile?.displayName ?? ChatDigest.localpart(userID), size: 88)
                        Text(profile?.displayName ?? ChatDigest.localpart(userID)).font(.title2.bold())
                        Text(userID).font(.footnote).foregroundStyle(Theme.quiet).textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                if let profile {
                    let about = ProfileAbout(profile: profile)
                    if !about.isEmpty {
                        Section {
                            field(.profileAbout, about.about)
                            field(.profileToonto, about.toonto)
                            field(.profileUg, about.ug)
                            field(.profileEastYear, EastYear(key: about.eastYear).map(words.eastYear) ?? "")
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.milk.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(words(.done)) { dismiss() } }
            }
            .task {
                profile = await session.profile(of: userID)
                #if DEBUG
                print("ui-check: карточка \(ChatDigest.localpart(userID)): о себе \(profile.map { ProfileAbout(profile: $0).isEmpty ? "пусто" : "есть" } ?? "не загружено")")
                #endif
            }
        }
    }

    @ViewBuilder private func field(_ title: Phrase, _ value: String) -> some View {
        if !value.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(words(title)).font(.caption).foregroundStyle(Theme.quiet)
                Text(value).foregroundStyle(Theme.ink).textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
        }
    }
}
