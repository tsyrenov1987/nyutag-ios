// Нютаг. Старая история под прежним ключом: карточка над списком чатов и окно ввода ключа.
// Ключ вводится один раз; дальше хранилище заперто паролем аккаунта, и на новых устройствах хватает пароля.

import SwiftUI
import UIKit

/// Карточка над списком: золотая полоска слева, замок, по нажатию открывает окно ключа.
struct LockedHistoryCard: View {
    @Environment(Words.self) private var words
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: "key.horizontal.fill")
                    .font(.title3).foregroundStyle(Theme.onGold)
                    .frame(width: 40, height: 40)
                    .background(Theme.gold, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(words(.historyLockedTitle)).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                    Text(words(.historyLockedLead)).font(.footnote).foregroundStyle(Theme.quiet)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.quiet)
            }
            .padding(12)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(alignment: .leading) { Theme.gold.frame(width: 5) }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("history-locked")
    }
}

struct HistoryKeyView: View {
    @Environment(Words.self) private var words
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var busy = false
    @State private var failure: AppSession.KeyFailure?
    @State private var done = false
    @FocusState private var focused: Bool
    /// Пароль этого входа ещё в памяти: ключ перезапрёт хранилище, и дальше хватит пароля.
    let canRelock: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(words(canRelock ? .historyKeyExplain : .historyKeyExplainNoPassword))
                        .foregroundStyle(Theme.quiet)

                    VStack(alignment: .trailing, spacing: 8) {
                        TextField(words(.recoveryKey), text: $key, axis: .vertical)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(2...4)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focused)
                            .accessibilityIdentifier("history-key")
                        Button(words(.paste)) {
                            if let text = UIPasteboard.general.string { key = text }
                        }
                        .font(.footnote.weight(.semibold)).foregroundStyle(Theme.sky)
                    }
                    .padding(16)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                    if let failure {
                        Label(message(failure), systemImage: "exclamationmark.bubble")
                            .font(.callout).foregroundStyle(Theme.ink)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.gold.opacity(0.18), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    if done {
                        Label(words(.historyOpened), systemImage: "checkmark.circle.fill")
                            .font(.callout.weight(.semibold)).foregroundStyle(Theme.read)
                    }

                    Button(action: submit) {
                        HStack(spacing: 10) {
                            if busy { ProgressView().tint(.white) }
                            Text(busy ? words(.openingHistory) : words(.openHistory)).font(.headline)
                        }
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .foregroundStyle(.white)
                        .background(Theme.sky.opacity(canSubmit ? 1 : 0.45),
                                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSubmit)
                    .accessibilityIdentifier("history-open")

                    // Ключа под рукой нет: ключи переписки может передать устройство, где вы уже вошли.
                    Button(words(.confirmFromDevice)) {
                        dismiss()
                        Task {
                            try? await Task.sleep(for: .milliseconds(600))
                            session.showDeviceCheck = true
                        }
                    }
                    .font(.callout.weight(.semibold)).foregroundStyle(Theme.sky)
                    .frame(maxWidth: .infinity)
                    .disabled(busy || done)
                    .accessibilityIdentifier("history-other-device")
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.milk.ignoresSafeArea())
            .navigationTitle(words(.historyLockedTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(words(.later)) { dismiss() } }
            }
            .onAppear { focused = true }
            #if DEBUG
            .task { await tryForScreenshots() }
            #endif
        }
    }

    private var canSubmit: Bool {
        !busy && !done && key.filter { !$0.isWhitespace }.count >= 8
    }

    private func submit() {
        guard canSubmit else { return }
        busy = true
        failure = nil
        Task {
            do throws(AppSession.KeyFailure) {
                try await session.openHistory(recoveryKey: key)
                done = true
                busy = false
                try? await Task.sleep(for: .seconds(1.2))
                dismiss()
            } catch {
                failure = error
                busy = false
            }
        }
    }

    private func message(_ failure: AppSession.KeyFailure) -> String {
        switch failure {
        case .wrongKey: words(.wrongKey)
        case .noNetwork, .broken: words(.noNetwork)
        }
    }

    #if DEBUG
    /// Самопроверка неверным ключом: SIMCTL_CHILD_NYUTAG_UI_TRY_KEY. Неверный ключ отсекается до любых записей.
    private func tryForScreenshots() async {
        guard let wrong = ProcessInfo.processInfo.environment["NYUTAG_UI_TRY_KEY"], key.isEmpty else { return }
        key = wrong
        submit()
        while busy { try? await Task.sleep(for: .milliseconds(200)) }
        print("ui-check: ключ \(failure == .wrongKey ? "отклонён" : done ? "принят" : "ошибка \(String(describing: failure))")")
    }
    #endif
}
