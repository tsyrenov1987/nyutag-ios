// Нютаг. Звонок на экране: стойка звонков (какой звонок идёт, его фаза, микрофон и громкая связь) и сам экран
// поверх приложения — входящий с «Принять/Отклонить», исходящий и разговор с таймером.

import AVFAudio
import AVFoundation
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
    /// Своя камера включена.
    private(set) var cameraOn = false
    private(set) var cameraDenied = false
    /// Картинка собеседника идёт: показываем её вместо аватара.
    private(set) var remoteVisible = false
    @ObservationIgnored let remoteFeed = PictureFeed()
    @ObservationIgnored let localFeed = PictureFeed()
    @ObservationIgnored private var videoWatch: Task<Void, Never>?

    @ObservationIgnored private var center: CallCenter?
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var follower: Task<Void, Never>?
    /// Будильники из VoIP-пуша, пришедшие раньше, чем поднялся вход.
    @ObservationIgnored private var waitingRings: [CallMessage] = []
    /// Имя собеседника по комнате: стойка не знает списка чатов.
    @ObservationIgnored var name: (String, String) -> String = { _, peer in peer }
    /// Имя участника группового звонка.
    @ObservationIgnored var memberName: (String, String) async -> String = { _, user in user }
    /// Кто сейчас в групповом звонке, кроме нас.
    private(set) var members: [String] = []
    @ObservationIgnored private var memberWatch: Task<Void, Never>?
    /// Трубку положили мы: коротких гудков не надо.
    @ObservationIgnored private var hungUpHere = false
    @ObservationIgnored private var lateRingback: Task<Void, Never>?

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
        case .calling, .alerting, .connecting, .live: true
        default: false
        }
    }

    var showsStrip: Bool { current != nil && folded }

    func dial(roomID: String, peer: String, video: Bool = false) async {
        guard let center, current == nil, await microphone() else { return }
        let camera = video ? await cameraAccess() : false
        guard let session = await center.dial(roomID: roomID, peer: peer, video: video) else { return }
        if video, !camera { await session.setCamera(false) }
        show(session)
    }

    func dialGroup(roomID: String) async {
        guard let center, current == nil, await microphone() else { return }
        guard let session = await center.dialGroup(roomID: roomID) else { return }
        show(session)
    }

    func toggleCamera() async {
        guard let current else { return }
        let wanted = !cameraOn
        if wanted, await !cameraAccess() { return }
        cameraOn = wanted
        if !wanted { localFeed.clear() }
        await current.setCamera(wanted)
    }

    func switchCamera() async {
        await current?.switchCamera()
    }

    private func cameraAccess() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        cameraDenied = !granted
        return granted
    }

    /// Кнопки экрана: через CallKit, он вернёт их сюда же (performAccept/performHangUp).
    func accept() async {
        guard let current else { return }
        CallRinger.shared.answer(current.callID)
    }

    func hangUp() async {
        guard let current else { return }
        hungUpHere = true
        CallRinger.shared.end(current.callID)
    }

    /// Принять. Без микрофона всё равно принимаем: звонок уже принят на экране CallKit, собеседника хотя бы слышно.
    func performAccept(_ callID: String) async {
        guard let current, current.callID == callID else { return }
        _ = await microphone()
        if current.video, await !cameraAccess() {
            cameraOn = false
            await current.setCamera(false)
        }
        await current.accept()
    }

    func performHangUp(_ callID: String) async {
        guard let current, current.callID == callID else { return }
        hungUpHere = true
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
        cameraOn = session.video
        cameraDenied = false
        remoteVisible = false
        remoteFeed.clear()
        localFeed.clear()
        members = []
        hungUpHere = false
        if session.group { watchMembers(session) }
        watchVideo(session)
        #if DEBUG
        selfCheck(session)
        #endif
        CallRinger.shared.track(session)
        follower?.cancel()
        follower = Task { [weak self] in
            var beeping = false
            for await phase in session.phases {
                let before = self?.phase
                self?.phase = phase
                // Видеозвонок по громкой: телефон держат перед собой.
                if case .live = phase, session.video { self?.speaker = true }
                beeping = self?.sound(phase, after: before, of: session) ?? false
                if beeping {
                    // Короткие гудки идут через сессию звука CallKit: о конце сообщаем системе, когда отзвучат.
                    Task { try? await Task.sleep(for: .seconds(1.8)); CallRinger.shared.follow(phase, of: session) }
                } else {
                    CallRinger.shared.follow(phase, of: session)
                }
                #if DEBUG
                print("ui-check: звонок \(session.callID.prefix(6)): \(phase)")
                #endif
            }
            // Итог висит на экране недолго, потом экран уходит.
            try? await Task.sleep(for: .seconds(beeping ? 2 : 1.5))
            guard let self, self.current === session else { return }
            #if DEBUG
            if let stats = await session.stats {
                print("ui-check: звонок итог: ушло \(stats.sent), пришло \(stats.received), сыграно \(stats.played), потеряно \(stats.lost)")
            }
            #endif
            self.current = nil
            self.phase = nil
            self.folded = false
            self.remoteVisible = false
            self.cameraOn = false
            self.members = []
            self.videoWatch?.cancel()
            self.memberWatch?.cancel()
        }
    }

    /// Гудки звонящего. Длинные — пока у собеседника звенит; если его телефон не ответил «звоню» (старая версия),
    /// всё равно через 5 с. Короткие — когда звонок оборвался не по нашей кнопке; тогда возвращает true.
    private func sound(_ phase: CallPhase, after before: CallPhase?, of session: CallSession) -> Bool {
        guard !session.group else { return false }
        let tones = CallTones.shared
        switch phase {
        case .calling:
            lateRingback?.cancel()
            lateRingback = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, self?.current === session, self?.phase == .calling else { return }
                tones.ringback()
            }
        case .alerting:
            lateRingback?.cancel()
            tones.ringback()
        case .ringing, .connecting, .live:
            lateRingback?.cancel()
            tones.stop()
        case .ended(let reason):
            lateRingback?.cancel()
            let wasOurs = switch before {
            case .calling, .alerting, .connecting, .live: true
            default: false
            }
            guard wasOurs, !hungUpHere, reason != .elsewhere else {
                tones.stop()
                return false
            }
            tones.ended()
            return true
        }
        return false
    }

    /// Участники группового звонка: кто пришёл и кто ушёл, раз в секунду.
    private func watchMembers(_ session: CallSession) {
        memberWatch?.cancel()
        memberWatch = Task { [weak self] in
            var known: [String] = []
            while !Task.isCancelled, await !session.phase.isEnded {
                let users = Array(Set(await session.others.map(\.user))).sorted()
                if users != known, let self {
                    known = users
                    var names: [String] = []
                    for user in users { names.append(await self.memberName(session.roomID, user)) }
                    guard self.current === session else { return }
                    self.members = names.sorted()
                    #if DEBUG
                    print("ui-check: в групповом звонке \(names.count) кроме нас")
                    #endif
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Кадры звонка — на слои экрана. Картинка собеседника пропала на 2,5 с или он выключил камеру — снова аватар.
    private func watchVideo(_ session: CallSession) {
        let remote = remoteFeed, local = localFeed
        let sink = VideoSink(
            remote: { picture in Task { @MainActor [weak self] in
                remote.show(picture)
                if self?.remoteVisible == false { self?.remoteVisible = true }
            } },
            local: { picture in Task { @MainActor in local.show(picture) } },
            remoteCameraOff: { Task { @MainActor [weak self] in
                self?.remoteVisible = false
                remote.clear()
            } })
        Task { await session.showVideo(sink) }
        videoWatch?.cancel()
        videoWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.current === session else { return }
                if self.remoteVisible, let last = remote.lastShown, Date().timeIntervalSince(last) > 2.5 {
                    self.remoteVisible = false
                }
            }
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
                if let video = await session.videoStats, video.sentFrames + video.receivedFrames > 0 {
                    print("ui-check: видео: ушло \(video.sentFrames) (ключевых \(video.sentKeyframes), пропущено \(video.skipped), \(video.bitRate / 1000) кбит/с), пришло \(video.receivedFrames), показано \(video.shownFrames) \(video.remoteWidth)×\(video.remoteHeight), битых \(video.brokenFrames)")
                }
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
            // Слой собеседника есть всегда, чтобы первый кадр лёг сразу; виден, пока идёт картинка.
            PictureView(feed: desk.remoteFeed)
                .ignoresSafeArea()
                .opacity(desk.remoteVisible ? 1 : 0)
            if desk.remoteVisible {
                LinearGradient(colors: [.black.opacity(0.45), .clear, .clear, .black.opacity(0.55)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            VStack(spacing: 18) {
                HStack(alignment: .top) {
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
                    if desk.cameraOn, desk.phase.map(Self.isTalking) == true {
                        preview(desk: desk)
                    }
                }
                .frame(minHeight: 44)
                .padding(.horizontal, 16)
                if desk.remoteVisible {
                    VStack(spacing: 4) {
                        Text(desk.peerName)
                            .font(.title2.weight(.semibold))
                            .lineLimit(1)
                        status.font(.headline.monospacedDigit())
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.4), radius: 6)
                } else {
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
                    if session?.group == true {
                        GroupMembers(names: desk.members)
                    }
                }
                if desk.micDenied || desk.cameraDenied {
                    Text(words(desk.micDenied ? .callMicDenied : .callCameraDenied))
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
        .animation(.smooth, value: desk.remoteVisible)
        .animation(.smooth, value: desk.cameraOn)
    }

    private static func isTalking(_ phase: CallPhase) -> Bool {
        switch phase {
        case .calling, .alerting, .connecting, .live: true
        default: false
        }
    }

    /// Своя камера в углу; нажатие меняет фронтальную и основную.
    private func preview(desk: CallDesk) -> some View {
        PictureView(feed: desk.localFeed)
            .frame(width: 104, height: 150)
            .clipShape(.rect(cornerRadius: 18))
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(6)
                    .shadow(radius: 3)
            }
            .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
            .onTapGesture { Task { await desk.switchCamera() } }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(words(.callFlip))
            .transition(.scale.combined(with: .opacity))
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
                RoundButton(symbol: desk.current?.video == true ? "video.fill" : "phone.fill", tint: Theme.read,
                            caption: words(.callAccept)) {
                    Task { await desk.accept() }
                }
            }
        case .ended, nil:
            EmptyView()
        default:
            HStack(spacing: 16) {
                RoundButton(symbol: desk.muted ? "mic.slash.fill" : "mic.fill", tint: desk.muted ? .white : nil,
                            caption: words(.callMute)) { desk.muted.toggle() }
                if desk.current?.group != true {
                    RoundButton(symbol: desk.cameraOn ? "video.fill" : "video.slash.fill", tint: desk.cameraOn ? .white : nil,
                                caption: words(.callCamera)) { Task { await desk.toggleCamera() } }
                }
                RoundButton(symbol: "speaker.wave.2.fill", tint: desk.speaker ? .white : nil,
                            caption: words(.callSpeaker)) { desk.speaker.toggle() }
                RoundButton(symbol: "phone.down.fill", tint: .red, caption: words(.callHangUp)) {
                    Task { await desk.hangUp() }
                }
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
        case .alerting: Text(words(.callAlerting))
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

/// Кто в групповом звонке: стеклянные плашки с именами; пока никого — «ждём участников».
private struct GroupMembers: View {
    @Environment(Words.self) private var words
    let names: [String]

    var body: some View {
        if names.isEmpty {
            Text(words(.callGroupWaiting))
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
        } else {
            VStack(spacing: 8) {
                Text(words(.callGroupMembers) + " \(names.count + 1)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
                FlowNames(names: names)
            }
            .padding(.horizontal, 24)
        }
    }
}

/// Имена в несколько строк, по ширине экрана.
private struct FlowNames: View {
    let names: [String]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
            ForEach(names, id: \.self) { name in
                HStack(spacing: 6) {
                    Pillow(seed: name, title: name, size: 22)
                    Text(name)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .glassEffect(.regular, in: .capsule)
            }
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
    static let callAlerting = Phrase(bxr: "Залгажа байна…", ru: "Идут гудки…", en: "Ringing…")
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
    static let callVideoAction = Phrase(bxr: "Видео залгаха", ru: "Видеозвонок", en: "Video call")
    static let callGroupAction = Phrase(bxr: "Бүлэгөөр залгаха", ru: "Групповой звонок", en: "Group call")
    static let callGroupWaiting = Phrase(bxr: "Хабаадагшадые хүлеэжэ байна…", ru: "Ждём участников…",
                                         en: "Waiting for others…")
    static let callGroupMembers = Phrase(bxr: "Хабаадагшад:", ru: "Участников:", en: "Participants:")
    static let callCamera = Phrase(bxr: "Камера", ru: "Камера", en: "Camera")
    static let callFlip = Phrase(bxr: "Камера һэлгэхэ", ru: "Сменить камеру", en: "Switch camera")
    static let callCameraDenied = Phrase(bxr: "Камера хаагдаатай. Тохиргоо соо Нютагта зүбшөөрэгты.",
                                         ru: "Нет доступа к камере. Разрешите её Нютагу в Настройках.",
                                         en: "No camera access. Allow it for Nyutag in Settings.")
    static let callMicDenied = Phrase(bxr: "Микрофон хаагдаатай. Тохиргоо соо Нютагта зүбшөөрэгты.",
                                      ru: "Нет доступа к микрофону. Разрешите его Нютагу в Настройках.",
                                      en: "No microphone access. Allow it for Nyutag in Settings.")
}
