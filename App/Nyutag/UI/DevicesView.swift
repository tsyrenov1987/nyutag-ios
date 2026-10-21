// Нютаг. «Устройства»: где сейчас открыт аккаунт. Своё устройство первым и с пометкой; любое можно
// переименовать, чужое — отключить, подтвердив паролем. Своё отключается обычным выходом из меню.

import NyutagCore
import SwiftUI

struct DevicesView: View {
    @Environment(Words.self) private var words
    @Environment(AppSession.self) private var session
    @State private var devices: [AccountDevice] = []
    @State private var loading = true
    @State private var failure: String?
    @State private var renaming: AccountDevice?
    @State private var newName = ""
    @State private var signingOut: AccountDevice?

    var body: some View {
        List {
            Section {
                ForEach(devices) { device in
                    row(device)
                        .contextMenu {
                            Button(words(.renameDevice), systemImage: "pencil") { startRename(device) }
                            if device.deviceID != session.deviceID {
                                Button(words(.signOutDevice), systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                                    signingOut = device
                                }
                            }
                        }
                        .swipeActions {
                            if device.deviceID != session.deviceID {
                                Button(words(.signOutDevice), role: .destructive) { signingOut = device }
                            }
                            Button(words(.renameDevice)) { startRename(device) }.tint(Theme.sky)
                        }
                }
            } footer: {
                Text(words(.devicesLead))
            }
            if let failure { FailureNote(text: failure).listRowBackground(Color.clear) }
        }
        .overlay { if loading && devices.isEmpty { ProgressView() } }
        .scrollContentBackground(.hidden)
        .background(Theme.milk.ignoresSafeArea())
        .navigationTitle(words(.devices))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task {
            await load()
            #if DEBUG
            // Самопроверка: NYUTAG_UI_DEVICE_RENAME=<id>=<имя>, NYUTAG_UI_DEVICE_SIGNOUT=<id>=<пароль>.
            let env = ProcessInfo.processInfo.environment
            if let value = env["NYUTAG_UI_DEVICE_RENAME"], let cut = value.firstIndex(of: "="),
               let device = devices.first(where: { $0.deviceID == String(value[..<cut]) }) {
                await rename(device, to: String(value[value.index(after: cut)...]))
            }
            if let value = env["NYUTAG_UI_DEVICE_SIGNOUT"], let cut = value.firstIndex(of: "="),
               let device = devices.first(where: { $0.deviceID == String(value[..<cut]) }) {
                do {
                    try await session.signOutDevice(device.deviceID, password: String(value[value.index(after: cut)...]))
                    print("ui-check: вышли на устройстве \(device.deviceID)")
                } catch {
                    print("ui-check: выход на устройстве отклонён: \(error)")
                }
                await load()
            }
            #endif
        }
        .alert(words(.renameDevice), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(words(.unnamedDevice), text: $newName)
            Button(words(.save)) {
                if let device = renaming { Task { await rename(device, to: newName) } }
            }
            Button(words(.cancel), role: .cancel) {}
        }
        .sheet(item: $signingOut) { device in
            DeviceSignOutView(device: device) { Task { await load() } }
        }
    }

    private func row(_ device: AccountDevice) -> some View {
        let mine = device.deviceID == session.deviceID
        return HStack(spacing: 14) {
            Image(systemName: mine ? "iphone.gen3" : "laptopcomputer.and.iphone")
                .font(.title3).foregroundStyle(mine ? Theme.sky : Theme.quiet).frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(device.displayName?.isEmpty == false ? device.displayName! : words(.unnamedDevice))
                    .foregroundStyle(Theme.ink)
                if mine {
                    Text(words(.thisDevice)).font(.caption.weight(.semibold)).foregroundStyle(Theme.sky)
                } else if let seen = device.lastSeen {
                    Text(words(.lastSeen, seen.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened,
                                                                          locale: words.lang?.locale ?? Locale(identifier: "ru")))))
                        .font(.caption).foregroundStyle(Theme.quiet)
                }
                // Через дверь сервер видит адрес входа, а не телефона — такой адрес ничего не говорит, не показываем.
                Text([device.deviceID, device.lastSeenIP.flatMap { $0 == "127.0.0.1" ? nil : $0 }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2.monospaced()).foregroundStyle(Theme.quiet)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(mine ? "device-mine" : "device-\(device.deviceID)")
    }

    private func startRename(_ device: AccountDevice) {
        newName = device.displayName ?? ""
        renaming = device
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            devices = try await session.devices()
            failure = nil
            #if DEBUG
            print("ui-check: устройства \(devices.count), своё первым: \(devices.first?.deviceID == session.deviceID)")
            #endif
        } catch {
            failure = words(error == .noNetwork ? .noNetwork : .devicesFailed)
        }
    }

    private func rename(_ device: AccountDevice, to name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            try await session.renameDevice(device.deviceID, to: name)
            #if DEBUG
            print("ui-check: устройство \(device.deviceID) переименовано: \(name)")
            #endif
            await load()
        } catch {
            failure = words(.devicesFailed)
        }
    }
}

/// Отключение чужого устройства: что будет, пароль, красная кнопка.
struct DeviceSignOutView: View {
    @Environment(Words.self) private var words
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let device: AccountDevice
    let onDone: () -> Void
    @State private var password = ""
    @State private var busy = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(device.displayName ?? device.deviceID).font(.headline).foregroundStyle(Theme.ink)
                    Text(words(.signOutDeviceLead)).foregroundStyle(Theme.ink)
                    Text(words(.deleteAccountPassword)).font(.footnote).foregroundStyle(Theme.quiet)
                    SecureField(words(.password), text: $password)
                        .textContentType(.password)
                        .padding(16)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .accessibilityIdentifier("device-signout-password")
                    if let failure { FailureNote(text: failure) }
                    Button {
                        Task { await signOut() }
                    } label: {
                        HStack {
                            if busy { ProgressView().tint(.white) }
                            Text(words(.signOutDevice)).font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(busy || password.isEmpty)
                    .accessibilityIdentifier("device-signout-confirm")
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.milk.ignoresSafeArea())
            .navigationTitle(words(.devices))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(words(.cancel)) { dismiss() } }
            }
        }
    }

    private func signOut() async {
        busy = true
        defer { busy = false }
        failure = nil
        do {
            try await session.signOutDevice(device.deviceID, password: password)
            #if DEBUG
            print("ui-check: вышли на устройстве \(device.deviceID)")
            #endif
            onDone()
            dismiss()
        } catch .wrongPassword {
            failure = words(.wrongPassword)
        } catch .noNetwork {
            failure = words(.noNetwork)
        } catch {
            failure = words(.devicesFailed)
        }
    }
}
