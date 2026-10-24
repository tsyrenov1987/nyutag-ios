// Нютаг. Подтверждение входа своим другим устройством. Новый вход просит, старое устройство отвечает «это я»,
// оба показывают семь эмодзи; человек сверяет их глазами. После этого новый вход получает ключи переписки.

import NyutagCore
import SwiftUI

struct DeviceCheckView: View {
    @Environment(Words.self) private var words
    @Environment(AppSession.self) private var session
    @State private var asking = false
    @State private var failure: AppSession.DeviceCheckFailure?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    content
                }
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.milk.ignoresSafeArea())
            .navigationTitle(words(title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(words(finished ? .close : .cancel)) { Task { await session.closeDeviceCheck() } }
                }
            }
            .task { await askIfNeeded() }
            #if DEBUG
            .task(id: session.deviceCheck?.state) { await answerForScreenshots() }
            #endif
        }
        .interactiveDismissDisabled(!finished)
    }

    private var flow: VerificationFlow? { session.deviceCheck }

    private var finished: Bool {
        switch flow?.state {
        case .done, .cancelled: !session.awaitingKeys
        case nil: failure != nil
        default: false
        }
    }

    private var title: Phrase { flow?.incoming == true ? .newSignInTitle : .otherDeviceTitle }

    @ViewBuilder private var content: some View {
        if let failure {
            note(symbol: "exclamationmark.bubble", tint: Theme.gold,
                 text: words(failure == .noOtherDevice ? .noOtherDevice : .noNetwork))
        } else if let flow {
            switch flow.state {
            case .requested where flow.incoming:
                note(symbol: "iphone.gen3", tint: Theme.sky,
                     text: words(.newSignInAsk, session.deviceCheckName ?? words(.anotherDevice)))
                wide(words(.itsMe), fill: Theme.sky) { await session.acceptDeviceCheck() }
                wide(words(.notMe), fill: Theme.card, ink: Theme.ink) { await session.rejectDeviceCheck(mismatch: false) }
            case .requested:
                note(symbol: "iphone.gen3", tint: Theme.sky, text: words(.otherDeviceWait))
                ProgressView()
            case .ready, .started:
                waiting(words(.matchingKeys))
            case .comparing:
                Text(words(.compareEmoji)).font(.headline).foregroundStyle(Theme.ink).multilineTextAlignment(.center)
                EmojiGrid(symbols: flow.emojiSymbols, english: words.lang == .en)
                wide(words(.emojiMatch), fill: Theme.sky) { await session.confirmEmoji() }
                wide(words(.emojiDiffer), fill: Theme.card, ink: Theme.ink) { await session.rejectDeviceCheck(mismatch: true) }
            case .confirmed:
                waiting(words(.waitOtherSide))
            case .done:
                note(symbol: "checkmark.seal.fill", tint: Theme.read, text: words(.signInConfirmed))
                if session.awaitingKeys {
                    waiting(words(.keysComing))
                } else if case .opened = session.history {
                    Label(words(.historyOpened), systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.semibold)).foregroundStyle(Theme.read)
                }
            case .cancelled(let code, _):
                note(symbol: "xmark.octagon", tint: Theme.gold,
                     text: words(code == "m.mismatched_sas" ? .emojiMismatch : .checkStopped))
            }
        } else {
            ProgressView()
        }
    }

    private func note(symbol: String, tint: Color, text: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 44)).foregroundStyle(tint)
            Text(text).font(.body).foregroundStyle(Theme.ink).multilineTextAlignment(.center)
        }
        .padding(.top, 12)
    }

    private func waiting(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(text).font(.callout).foregroundStyle(Theme.quiet)
        }
        .padding(.top, 8)
    }

    private func wide(_ label: String, fill: Color, ink: Color = .white, action: @escaping () async -> Void) -> some View {
        Button {
            guard !busy else { return }
            busy = true
            Task {
                await action()
                busy = false
            }
        } label: {
            Text(label).font(.headline)
                .frame(maxWidth: .infinity, minHeight: 54)
                .foregroundStyle(ink)
                .background(fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    /// Окно открыто карточкой «подтвердите вход»: запрос уходит сразу.
    private func askIfNeeded() async {
        guard session.deviceCheck == nil, !asking else { return }
        asking = true
        do throws(AppSession.DeviceCheckFailure) {
            try await session.askOtherDevice()
        } catch {
            failure = error
        }
    }

    #if DEBUG
    /// Самопроверка с Мака: NYUTAG_UI_DEVICE=answer|ask. На чужой запрос отвечаем «это я», эмодзи подтверждаем
    /// через 8 секунд, чтобы успеть снять экран.
    private func answerForScreenshots() async {
        guard ProcessInfo.processInfo.environment["NYUTAG_UI_DEVICE"] != nil, let flow else { return }
        print("ui-check: проверка устройства \(flow.state)\(flow.emoji.map { _ in " эмодзи " + flow.emojiSymbols.map(\.emoji).joined() } ?? "")")
        switch flow.state {
        case .requested where flow.incoming:
            try? await Task.sleep(for: .seconds(2))
            await session.acceptDeviceCheck()
        case .comparing:
            try? await Task.sleep(for: .seconds(8))
            await session.confirmEmoji()
        default: break
        }
    }
    #endif
}

/// Семь эмодзи из сверки с подписями, две строки.
struct EmojiGrid: View {
    let symbols: [(emoji: String, name: String, nameRU: String)]
    let english: Bool

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 14) {
            ForEach(Array(symbols.enumerated()), id: \.offset) { _, item in
                VStack(spacing: 6) {
                    Text(item.emoji).font(.system(size: 40))
                    Text(english ? item.name : item.nameRU)
                        .font(.caption).foregroundStyle(Theme.quiet).lineLimit(2).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 84)
            }
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
