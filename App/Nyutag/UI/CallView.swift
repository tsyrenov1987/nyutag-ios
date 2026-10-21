// Нютаг. Звонок на экране: стойка звонков (какой звонок идёт, его фаза, микрофон и громкая связь) и сам экран
// поверх приложения — входящий с «Принять/Отклонить», исходящий и разговор с таймером.

import AVFAudio
import NyutagCore
import Observation
import SwiftUI

@MainActor @Observable
final class CallDesk {
    private(set) var current: CallSession?
    private(set) var phase: CallPhase?
    private(set) var peerName = ""
    private(set) var micDenied = false
    /// Звонок свёрнут в полоску над чатами: можно переписываться, не кладя трубку.
    var folded = false
    var muted = false {
        didSet {
            guard muted != oldValue, let call = current else { return }
            let muted = muted
            Task { await call.setMuted(muted) }
            CallRinger.shared.setMuted(muted, call.callID)
        }
    }
    var speaker = false {
        didSet { DeviceVoice.setSpeaker(speaker) }
    }

    @ObservationIgnored private var center: CallCenter?
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var follower: Task<Void, Never>?
    /// Будильники из VoIP-пуша, пришедшие раньше, чем поднялся вход.
    @ObservationIgnored private var waitingRings: [CallMessage] = []
    /// Имя собеседника по комнате: стойка не знает списка чатов.
    @ObservationIgnored var name: (String, String) -> String = { _, peer in peer }

    func attach(_ center: CallCenter) {
        self.center = center
        CallRinger.shared.desk = self
        let rings = waitingRings
        waitingRings = []
        Task { for ring in rings { await center.absorb(ring) } }
        listener?.cancel()
        listener = Task { [weak self] in
            for await session in center.incoming {
                self?.show(session)
            }
        }
    }

    func detach() async {
        listener?.cancel()
        await current?.hangUp()
        center = nil
    }

    /// Свернуть можно идущий звонок; входящий ещё ждёт ответа на весь экран.
    var canFold: Bool {
        switch phase {
        case .calling, .connecting, .live: true
        default: false
        }
    }

    var showsStrip: Bool { current != nil && folded }

    func dial(roomID: String, peer: String) async {
        guard let center, current == nil, await microphone() else { return }
        guard let session = await center.dial(roomID: roomID, peer: peer) else { return }
        show(session)
    }

    /// Кнопки экрана: через CallKit, он вернёт их сюда же (performAccept/performHangUp).
    func accept() async {
        guard let current else { return }
        CallRinger.shared.answer(current.callID)
    }

    func hangUp() async {
        guard let current else { return }
        CallRinger.shared.end(current.callID)
    }

    /// Принять. Без микрофона всё равно принимаем: звонок уже принят на экране CallKit, собеседника хотя бы слышно.
    func performAccept(_ callID: String) async {
        guard let current, current.callID == callID else { return }
        _ = await microphone()
        await current.accept()
    }

    func performHangUp(_ callID: String) async {
        guard let current, current.callID == callID else { return }
        await current.hangUp()
    }

    func absorb(_ message: CallMessage) async {
        guard let center else { return waitingRings.append(message) }
        await center.absorb(message)
    }

    private func microphone() async -> Bool {
        let granted = await AVAudioApplication.requestRecordPermission()
        micDenied = !granted
        return granted
    }

    private func show(_ session: CallSession) {
        current = session
        peerName = name(session.roomID, session.peer)
        folded = false
        muted = false
        speaker = false
        #if DEBUG
        selfCheck(session)
        #endif
        CallRinger.shared.track(session)
        follower?.cancel()
        follower = Task { [weak self] in
            for await phase in session.phases {
                self?.phase = phase
                CallRinger.shared.follow(phase, of: session)
                #if DEBUG
                print("ui-check: звонок \(session.callID.prefix(6)): \(phase)")
                #endif
            }
            // Итог висит на экране недолго, потом экран уходит.
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, self.current === session else { return }
            #if DEBUG
            if let stats = await session.stats {
                print("ui-check: звонок итог: ушло \(stats.sent), пришло \(stats.received), сыграно \(stats.played), потеряно \(stats.lost)")
            }
            #endif
            self.current = nil
            self.phase = nil
            self.folded = false
        }
    }
}

#if DEBUG
extension CallDesk {
    /// Самопроверка на телефоне без касаний: NYUTAG_UI_CALL_ANSWER — принять входящий, NYUTAG_UI_CALL_SECONDS —
    /// положить трубку через столько секунд; пока идёт разговор, раз в 2 с в журнал уходят счётчики кадров.
    fileprivate func selfCheck(_ session: CallSession) {
        let env = ProcessInfo.processInfo.environment
        if !session.isCaller, env["NYUTAG_UI_CALL_ANSWER"] != nil {
            Task { try? await Task.sleep(for: .seconds(2)); await self.accept() }
        }
        if env["NYUTAG_UI_CALL_FOLD"] != nil {
            // Свернуть через 6 с разговора: проверка полоски над чатами.
            Task {
                while await !session.phase.isEnded {
                    if case .live = await session.phase { break }
                    try? await Task.sleep(for: .seconds(0.5))
                }
                try? await Task.sleep(for: .seconds(6))
                guard self.current === session else { return }
                self.folded = true
                print("ui-check: звонок свёрнут в полоску")
            }
        }
        if let seconds = env["NYUTAG_UI_CALL_SECONDS"].flatMap(Double.init) {
            Task { try? await Task.sleep(for: .seconds(seconds)); await session.hangUp() }
        }
        Task {
            let audio = AVAudioSession.sharedInstance()
            print("ui-check: микрофон \(AVAudioApplication.shared.recordPermission.rawValue), категория \(audio.category.rawValue), выход \(audio.currentRoute.outputs.map(\.portType.rawValue))")
            while await !session.phase.isEnded {
                try? await Task.sleep(for: .seconds(2))
                guard let stats = await session.stats else { continue }
                print("ui-check: звонок: ушло \(stats.sent), пришло \(stats.received), сыграно \(stats.played), потеряно \(stats.lost), микрофон \(String(format: "%.3f", stats.inputLevel)), динамик \(String(format: "%.3f", stats.outputLevel))")
            }
        }
    }
}
#endif

struct CallView: View {
    @Environment(Words.self) private var words
    @Environment(CallDesk.self) private var desk

    var body: some View {
        @Bindable var desk = desk
        let session = desk.current
        ZStack {
            LinearGradient(colors: [Theme.sky, Theme.milk.opacity(0.4)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 18) {
                HStack {
                    if desk.canFold {
                        Button { desk.folded = true } label: {
                            Image(systemName: "chevron.down")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .accessibilityLabel(words(.callFold))
                    }
                    Spacer()
                }
                .frame(height: 44)
                .padding(.horizontal, 16)
                Spacer().frame(height: 16)
                Pillow(seed: session?.roomID ?? "·", title: desk.peerName, size: 128)
                    .shadow(color: .black.opacity(0.2), radius: 18, y: 8)
                Text(desk.peerName)
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 24)
                status
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                if desk.micDenied {
                    Text(words(.callMicDenied))
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                Spacer()
                controls(desk: desk)
                    .padding(.bottom, 48)
            }
        }
        .animation(.smooth, value: desk.phase)
    }

    @ViewBuilder private var status: some View {
        CallStatus(phase: desk.phase)
    }

    @ViewBuilder private func controls(desk: CallDesk) -> some View {
        @Bindable var desk = desk
        switch desk.phase {
        case .ringing:
            HStack(spacing: 72) {
                RoundButton(symbol: "phone.down.fill", tint: .red, caption: words(.callDecline)) {
                    Task { await desk.hangUp() }
                }
                RoundButton(symbol: "phone.fill", tint: Theme.read, caption: words(.callAccept)) {
                    Task { await desk.accept() }
                }
            }
        case .ended, nil:
            EmptyView()
        default:
            HStack(spacing: 36) {
                RoundButton(symbol: desk.muted ? "mic.slash.fill" : "mic.fill", tint: desk.muted ? .white : nil,
                            caption: words(.callMute)) { desk.muted.toggle() }
                RoundButton(symbol: "phone.down.fill", tint: .red, caption: words(.callHangUp)) {
                    Task { await desk.hangUp() }
                }
                RoundButton(symbol: "speaker.wave.2.fill", tint: desk.speaker ? .white : nil,
                            caption: words(.callSpeaker)) { desk.speaker.toggle() }
            }
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds), 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func ending(_ reason: CallEndReason) -> Phrase {
        switch reason {
        case .hangUp: .callEnded
        case .declined: .callDeclined
        case .noAnswer: .callNoAnswer
        case .busy: .callBusy
        case .lost: .callLost
        case .elsewhere: .callElsewhere
        }
    }
}

/// Строка состояния звонка: фаза словами или часы разговора. Общая у экрана и полоски.
struct CallStatus: View {
    @Environment(Words.self) private var words
    let phase: CallPhase?

    var body: some View {
        switch phase {
        case .calling: Text(words(.callCalling))
        case .ringing: Text(words(.callIncoming))
        case .connecting: Text(words(.callConnecting))
        case .live(let since):
            TimelineView(.periodic(from: since, by: 1)) { context in
                Text(CallView.clock(context.date.timeIntervalSince(since)))
            }
        case .ended(let reason): Text(words(CallView.ending(reason)))
        case nil: Text(" ")
        }
    }
}

/// Свёрнутый звонок: стеклянная полоска над чатами. Нажатие разворачивает экран, справа — микрофон и отбой.
struct CallStrip: View {
    @Environment(Words.self) private var words
    @Environment(CallDesk.self) private var desk

    var body: some View {
        @Bindable var desk = desk
        HStack(spacing: 12) {
            Button { desk.folded = false } label: {
                HStack(spacing: 10) {
                    Pillow(seed: desk.current?.roomID ?? "·", title: desk.peerName, size: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(desk.peerName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        CallStatus(phase: desk.phase)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Theme.read)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(words(.callBack))
            StripButton(symbol: desk.muted ? "mic.slash.fill" : "mic.fill", tint: desk.muted ? Theme.sky : nil,
                        caption: words(.callMute)) { desk.muted.toggle() }
            StripButton(symbol: "phone.down.fill", tint: .red, caption: words(.callHangUp)) {
                Task { await desk.hangUp() }
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.horizontal, 12)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

private struct StripButton: View {
    let symbol: String
    let tint: Color?
    let caption: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint == nil ? Theme.ink : .white)
                .frame(width: 40, height: 40)
                .background(tint.map { Circle().fill($0) })
        }
        .buttonStyle(.plain)
        .accessibilityLabel(caption)
    }
}

/// Круглая кнопка звонка: цветная (принять, отбой, включённый режим) или стеклянная.
private struct RoundButton: View {
    let symbol: String
    let tint: Color?
    let caption: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.title.weight(.semibold))
                    .foregroundStyle(tint == .white ? Theme.sky : .white)
                    .frame(width: 72, height: 72)
                    .background(tint.map { Circle().fill($0) })
            }
            .buttonStyle(.plain)
            .glassEffect(tint == nil ? .regular.interactive() : .identity, in: .circle)
            .accessibilityLabel(caption)
            Text(caption)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.9))
        }
    }
}

extension Phrase {
    static let callAction = Phrase(bxr: "Залгаха", ru: "Позвонить", en: "Call")
    static let callCalling = Phrase(bxr: "Залгажа байна…", ru: "Звоним…", en: "Calling…")
    static let callIncoming = Phrase(bxr: "Танда залгажа байна", ru: "Входящий звонок", en: "Incoming call")
    static let callConnecting = Phrase(bxr: "Холбожо байна…", ru: "Соединяем…", en: "Connecting…")
    static let callEnded = Phrase(bxr: "Хөөрэлдөөн дууһаба", ru: "Звонок завершён", en: "Call ended")
    static let callDeclined = Phrase(bxr: "Татагалзаба", ru: "Отклонён", en: "Declined")
    static let callNoAnswer = Phrase(bxr: "Харюу үгы", ru: "Нет ответа", en: "No answer")
    static let callBusy = Phrase(bxr: "Забгүй", ru: "Занято", en: "Busy")
    static let callLost = Phrase(bxr: "Холбоо таһарба", ru: "Связь прервалась", en: "Connection lost")
    static let callElsewhere = Phrase(bxr: "Ондоо түхеэрэмжэ дээрэ абаба", ru: "Принят на другом устройстве",
                                      en: "Answered on another device")
    static let callAccept = Phrase(bxr: "Абаха", ru: "Принять", en: "Accept")
    static let callDecline = Phrase(bxr: "Татагалзаха", ru: "Отклонить", en: "Decline")
    static let callHangUp = Phrase(bxr: "Дуусгаха", ru: "Завершить", en: "End")
    static let callMute = Phrase(bxr: "Микрофон", ru: "Микрофон", en: "Mute")
    static let callSpeaker = Phrase(bxr: "Динамик", ru: "Динамик", en: "Speaker")
    static let callFold = Phrase(bxr: "Хуряаха", ru: "Свернуть", en: "Minimize")
    static let callBack = Phrase(bxr: "Хөөрэлдөөндэ бусаха", ru: "Вернуться к звонку", en: "Back to call")
    static let callMicDenied = Phrase(bxr: "Микрофон хаагдаатай. Тохиргоо соо Нютагта зүбшөөрэгты.",
                                      ru: "Нет доступа к микрофону. Разрешите его Нютагу в Настройках.",
                                      en: "No microphone access. Allow it for Nyutag in Settings.")
}
