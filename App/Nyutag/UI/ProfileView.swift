// Нютаг. Профиль: своё имя и «о себе» (тоонто нютаг, уг гарбал, восточный год) — правка, чужое — карточка.

import NyutagCore
import PhotosUI
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
    @State private var photoItem: PhotosPickerItem?
    @State private var photoBusy = false
    @State private var photoFailed = false
    @State private var viewingAvatar = false

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    Button { viewingAvatar = session.myAvatarURL != nil } label: {
                        Pillow(seed: session.me ?? "", title: name.isEmpty ? ChatDigest.localpart(session.me ?? "") : name,
                               size: 96, avatar: session.myAvatarURL)
                            .overlay { if photoBusy { ProgressView().tint(.white) } }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("profile-avatar")
                    HStack(spacing: 16) {
                        PhotosPicker(selection: $photoItem, matching: .images) {
                            Label(words(.avatarChange), systemImage: "photo")
                        }
                        .accessibilityIdentifier("profile-avatar-pick")
                        if session.myAvatarURL != nil {
                            Button(words(.avatarRemove), systemImage: "trash") {
                                Task { await setAvatar(nil) }
                            }
                            .accessibilityIdentifier("profile-avatar-remove")
                        }
                    }
                    .font(.subheadline)
                    .disabled(photoBusy)
                    if photoFailed { Text(words(.avatarFailed)).font(.footnote).foregroundStyle(.red) }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .listRowBackground(Color.clear)
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
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                photoItem = nil
                await setAvatar(data)
            }
        }
        .fullScreenCover(isPresented: $viewingAvatar) {
            if let url = session.myAvatarURL { AvatarViewer(url: url, title: name) }
        }
    }

    /// Снимок → квадрат 512 px → на сервер. `nil` — убрать аватар.
    private func setAvatar(_ picked: Data?) async {
        photoBusy = true
        defer { photoBusy = false }
        var jpeg: Data?
        if let picked {
            jpeg = await Task.detached(priority: .userInitiated) { ImageMemory.squareJPEG(picked, side: 512) }.value
            guard jpeg != nil else { photoFailed = true; return }
        }
        photoFailed = !(await session.setAvatar(jpeg))
    }

    private func load() async {
        guard old == nil, let me = session.me, let profile = await session.profile(of: me) else { return }
        old = profile
        name = profile.displayName ?? ChatDigest.localpart(me)
        about = ProfileAbout(profile: profile)
        hasPhone = await session.hasPhone()
        #if DEBUG
        // NYUTAG_UI_AVATAR=set — поставить аватар из Documents/ui-avatar.jpg, remove — убрать, view — открыть во весь экран.
        if let mode = ProcessInfo.processInfo.environment["NYUTAG_UI_AVATAR"] {
            switch mode {
            case "set":
                let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: "ui-avatar.jpg")
                await setAvatar(try? Data(contentsOf: file))
            case "remove": await setAvatar(nil)
            case "view": viewingAvatar = session.myAvatarURL != nil
            default: break
            }
            print("ui-check: аватар-хук \(mode): \(photoFailed ? "ошибка" : "ок"), профиль \(session.myAvatarURL ?? "без фото")")
        }
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
    @State private var askBlock = false
    @State private var failed = false
    @State private var viewingAvatar = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 8) {
                        Button { viewingAvatar = profile?.avatarURL != nil } label: {
                            Pillow(seed: userID, title: profile?.displayName ?? ChatDigest.localpart(userID), size: 88,
                                   avatar: profile?.avatarURL)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("person-avatar")
                        Text(profile?.displayName ?? ChatDigest.localpart(userID)).font(.title2.bold())
                        Text(userID).font(.footnote).foregroundStyle(Theme.quiet).textSelection(.enabled)
                        if session.isBlocked(userID) {
                            Label(words(.blocked), systemImage: "hand.raised.fill").font(.footnote).foregroundStyle(Theme.quiet)
                        }
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
                if userID != session.me {
                    Section {
                        if session.isBlocked(userID) {
                            Button(words(.unblock)) { Task { failed = !(await session.setBlocked(userID, false)) } }
                                .foregroundStyle(Theme.ink)
                                .accessibilityIdentifier("person-unblock")
                        } else {
                            Button(words(.block), role: .destructive) { askBlock = true }
                                .accessibilityIdentifier("person-block")
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.milk.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(words(.done)) { dismiss() } }
            }
            .confirmationDialog(words(.blockAsk), isPresented: $askBlock, titleVisibility: .visible) {
                Button(words(.block), role: .destructive) { Task { failed = !(await session.setBlocked(userID, true)) } }
                Button(words(.cancel), role: .cancel) {}
            }
            .alert(words(.cantDo), isPresented: $failed) { Button(words(.done)) {} }
            .fullScreenCover(isPresented: $viewingAvatar) {
                if let url = profile?.avatarURL {
                    AvatarViewer(url: url, title: profile?.displayName ?? ChatDigest.localpart(userID))
                }
            }
            .task {
                profile = await session.profile(of: userID)
                #if DEBUG
                print("ui-check: карточка \(ChatDigest.localpart(userID)): о себе \(profile.map { ProfileAbout(profile: $0).isEmpty ? "пусто" : "есть" } ?? "не загружено"), фото \(profile?.avatarURL ?? "нет")")
                if ProcessInfo.processInfo.environment["NYUTAG_UI_AVATAR"] == "view" { viewingAvatar = profile?.avatarURL != nil }
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

/// Аватар во весь экран: тёмный фон, картинка целиком, щипок для приближения, закрыть кнопкой или касанием.
struct AvatarViewer: View {
    @Environment(Words.self) private var words
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let url: String
    let title: String
    @State private var image: UIImage?
    @State private var broken = false
    @State private var zoom: CGFloat = 1
    @State private var pinch: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .scaleEffect(zoom * pinch)
                    .gesture(MagnifyGesture()
                        .onChanged { pinch = $0.magnification }
                        .onEnded { _ in
                            zoom = min(max(zoom * pinch, 1), 4)
                            pinch = 1
                        })
            } else if broken {
                Image(systemName: "photo.badge.exclamationmark").font(.largeTitle).foregroundStyle(.white.opacity(0.7))
            } else {
                ProgressView().tint(.white)
            }
        }
        .overlay(alignment: .top) {
            HStack {
                Text(title).font(.headline).foregroundStyle(.white).lineLimit(1)
                Spacer()
                Button(words(.done)) { dismiss() }
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("avatar-close")
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .onTapGesture { if zoom == 1 { dismiss() } else { zoom = 1 } }
        .task {
            image = await session.avatarFull(url)
            broken = image == nil
            #if DEBUG
            print("ui-check: аватар во весь экран \(image.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "не загружен")")
            #endif
        }
    }
}
