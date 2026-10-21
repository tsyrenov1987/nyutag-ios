// Нютаг. Один звонок один на один: от будильника до отбоя.
// Звонящий шлёт ring (открыто, ради VoIP-пуша) и offer со своим ключом; принявший отвечает answer со своим.
// Из пары ключей обе стороны выводят слот релея и ключи кадров, подключаются к релею и, когда в слоте оба,
// включают звук. Время разговора идёт с этого момента. Обрыв связи до 20 с переживаем переподключением.
// Видео принимается в любом звонке; своя камера включается сама только в видеозвонке, в голосовом — кнопкой.
// Групповой (голос): начавший шлёт ring с `group` и join со случайным слотом, своим ключом и меткой, и сразу ждёт
// в слоте. Принявший шлёт join с тем же слотом. Каждый слушает всех, чьи join видел. Отклонивший молчит.
// Ушедший шлёт leave; никто так и не пришёл — начавший шлёт end, и у остальных будильник гаснет.

import Foundation
import Synchronization

public enum CallPhase: Sendable, Equatable {
    /// Мы звоним, собеседник ещё не ответил.
    case calling
    /// Звонят нам.
    case ringing
    /// Ответ есть, сводим связь через релей.
    case connecting
    case live(since: Date)
    case ended(CallEndReason)

    public var isEnded: Bool {
        if case .ended = self { return true }
        return false
    }
}

/// Всё, чем звонок пользуется снаружи: подменяется в тестах.
public struct CallEnvironment: Sendable {
    public var me: String
    public var deviceID: String
    /// Отправить сигнал в комнату (шифром, если комната шифрованная и сигнал не ring).
    public var post: @Sendable (CallSignal, String) async throws -> Void
    public var openTransport: @Sendable (String) async -> (any CallTransport)?
    public var makeVoice: @Sendable () -> any VoiceIO
    /// Камера. `nil` — у устройства камеры нет: видео только принимаем.
    public var makeCamera: @Sendable () -> (any VideoSource)? = { nil }
    public var ringTimeout: Duration = .seconds(45)
    public var connectTimeout: Duration = .seconds(20)
    public var lossGrace: Duration = .seconds(20)
    /// Столько без единого кадра — связь считаем оборванной, даже если релей держит обе стороны (повисший канал
    /// собеседника): переподключаемся и ждём lossGrace. Собеседник шлёт кадры всегда, и с выключенным микрофоном.
    public var silenceLimit: Duration = .seconds(5)
    public var retryDelay: Duration = .seconds(1)

    public init(me: String, deviceID: String, post: @escaping @Sendable (CallSignal, String) async throws -> Void,
                openTransport: @escaping @Sendable (String) async -> (any CallTransport)?,
                makeVoice: @escaping @Sendable () -> any VoiceIO) {
        self.me = me
        self.deviceID = deviceID
        self.post = post
        self.openTransport = openTransport
        self.makeVoice = makeVoice
    }
}

/// Канал кадров к собеседнику: релей или подделка в тестах.
public protocol CallTransport: Sendable {
    var inbound: AsyncStream<RelayInbound> { get }
    func send(_ packet: Data)
    func close()
    /// Сколько байт ещё не ушло в сеть: по нему видео уступает голосу.
    var backlog: Int { get }
}

extension CallTransport {
    public var backlog: Int { 0 }
}

extension RelayLink: CallTransport {}

public actor CallSession {
    public nonisolated let callID: String
    public nonisolated let roomID: String
    public nonisolated let peer: String
    public nonisolated let isCaller: Bool
    public nonisolated let video: Bool
    /// Групповой звонок в комнате; `peer` — начавший его (у начавшего — комната).
    public nonisolated let group: Bool
    /// Смены фазы для экрана звонка. Последняя — `.ended`, после неё поток закрывается.
    public nonisolated let phases: AsyncStream<CallPhase>
    private let phaseSink: AsyncStream<CallPhase>.Continuation

    public private(set) var phase: CallPhase
    private let env: CallEnvironment
    private let keys = CallKeyPair()
    private var theirKey: Data?
    private var acceptRequested = false
    private var pipe: VoicePipe?
    private var voice: (any VoiceIO)?
    private var videoPipe: VideoPipe?
    private var camera: (any VideoSource)?
    private var cameraWanted: Bool
    private let outbox = Outbox()
    private var slot: String?
    private var reader: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var lossTimer: Task<Void, Never>?
    private var watch: Task<Void, Never>?
    private var lastHeard = ContinuousClock.now
    private var pendingSink: VideoSink?
    // Групповой звонок.
    private let groupKey = CallSecret.makeGroupKey()
    private let groupTag = UInt32.random(in: 1...UInt32.max)
    private var members: [String: CallMember] = [:]
    private var joined = false

    init(callID: String, roomID: String, peer: String, isCaller: Bool, video: Bool, group: Bool = false,
         env: CallEnvironment) {
        self.callID = callID
        self.roomID = roomID
        self.peer = peer
        self.isCaller = isCaller
        self.video = group ? false : video
        self.group = group
        self.env = env
        cameraWanted = self.video
        phase = isCaller ? .calling : .ringing
        (phases, phaseSink) = AsyncStream.makeStream(of: CallPhase.self, bufferingPolicy: .bufferingNewest(8))
        phaseSink.yield(phase)
    }

    // MARK: Звонящий

    func dial() async {
        if group { return await dialGroup() }
        do {
            try await env.post(.ring(callID: callID, video: video, lifetime: env.ringTimeout), roomID)
            try await env.post(.offer(callID: callID, key: keys.publicKey, video: video), roomID)
        } catch {
            return await finish(.lost, notify: false)
        }
        arm(after: env.ringTimeout, .noAnswer, notify: true)
    }

    private func dialGroup() async {
        slot = CallID.make()
        do {
            try await env.post(.ring(callID: callID, video: false, lifetime: env.ringTimeout, group: true), roomID)
        } catch {
            return await finish(.lost, notify: false)
        }
        arm(after: env.ringTimeout, .noAnswer, notify: true)
        await joinGroup()
    }

    /// Участники группового звонка, кроме нас: кто прислал join и не ушёл.
    public var others: [CallMember] { members.values.sorted { $0.user < $1.user } }

    // MARK: Нам звонят

    /// Будильник звенит до `until`; не ответили — пропущенный, без сигнала в комнату.
    func ring(until: Date) {
        let left = max(until.timeIntervalSinceNow, 1)
        arm(after: .milliseconds(Int(left * 1000)), .noAnswer, notify: false)
    }

    public func accept() async {
        guard phase == .ringing else { return }
        acceptRequested = true
        set(.connecting)
        arm(after: env.connectTimeout, .lost, notify: true)
        if group {
            if slot != nil { await joinGroup() }
        } else if theirKey != nil {
            await answer()
        }
    }

    private func joinGroup() async {
        guard let slot, !joined, !phase.isEnded,
              let secret = CallSecret.group(slot: slot, key: groupKey) else { return }
        joined = true
        do {
            try await env.post(.join(callID: callID, slot: slot, key: groupKey, tag: groupTag, deviceID: env.deviceID), roomID)
        } catch {
            return await finish(.lost, notify: false)
        }
        let outbox = outbox
        guard let pipe = VoicePipe(group: secret, tag: groupTag, send: { packet in outbox.current?.send(packet) }) else {
            return await finish(.lost, notify: true)
        }
        for member in members.values {
            if let theirs = CallSecret.group(slot: slot, key: member.key) { pipe.add(tag: member.tag, secret: theirs) }
        }
        self.pipe = pipe
        openLink()
    }

    private func answer() async {
        guard let theirKey, let secret = try? keys.secret(with: theirKey, callID: callID, isCaller: false) else {
            return await finish(.lost, notify: true)
        }
        do {
            try await env.post(.answer(callID: callID, key: keys.publicKey, deviceID: env.deviceID), roomID)
        } catch {
            return await finish(.lost, notify: false)
        }
        connect(secret)
    }

    // MARK: Сигналы из комнаты

    func handle(_ message: CallMessage) async {
        guard message.signal.callID == callID, !phase.isEnded else { return }
        let mine = message.sender == env.me
        if group { return await handleGroup(message, mine: mine) }
        switch message.signal {
        case .ring:
            break
        case .offer(_, let key, _):
            guard !isCaller, !mine, message.sender == peer, theirKey == nil else { return }
            theirKey = key
            if acceptRequested { await answer() }
        case .answer(_, let key, let device):
            if mine {
                // Своё эхо или ответ с другого нашего устройства.
                if !isCaller, device != env.deviceID, phase == .ringing { await finish(.elsewhere, notify: false) }
                return
            }
            guard isCaller, phase == .calling, message.sender == peer,
                  let secret = try? keys.secret(with: key, callID: callID, isCaller: true) else { return }
            set(.connecting)
            arm(after: env.connectTimeout, .lost, notify: true)
            connect(secret)
        case .end(_, let reason):
            if mine {
                // Отклонили на другом нашем устройстве; своё эхо сюда не доходит — звонок уже закончен.
                if !isCaller, phase == .ringing { await finish(.elsewhere, notify: false) }
                return
            }
            guard message.sender == peer else { return }
            await finish(reason, notify: false)
        case .join, .leave:
            break
        }
    }

    private func handleGroup(_ message: CallMessage, mine: Bool) async {
        switch message.signal {
        case .join(_, let slot, let key, let tag, let device):
            if mine, device == env.deviceID { return }
            if mine, phase == .ringing { return await finish(.elsewhere, notify: false) }
            if self.slot == nil { self.slot = slot }
            guard slot == self.slot else { return }
            let id = message.sender + "|" + device
            if let old = members[id] { pipe?.remove(tag: old.tag) }
            members[id] = CallMember(user: message.sender, deviceID: device, key: key, tag: tag)
            if let secret = CallSecret.group(slot: slot, key: key) { pipe?.add(tag: tag, secret: secret) }
            if acceptRequested, !joined { await joinGroup() }
        case .leave(_, let device):
            guard let old = members.removeValue(forKey: message.sender + "|" + device) else { return }
            pipe?.remove(tag: old.tag)
            if members.isEmpty, case .live = phase { await finish(.hangUp, notify: true) }
        case .end(_, let reason):
            // Начавший сдался, пока никто не пришёл.
            guard !mine, message.sender == peer else { return }
            if case .live = phase { return }
            await finish(reason, notify: false)
        case .ring, .offer, .answer:
            break
        }
    }

    // MARK: Разговор

    public func hangUp() async {
        // Групповой отклоняем молча: остальные участники ждут других.
        await finish(phase == .ringing ? .declined : .hangUp, notify: !(group && phase == .ringing))
    }

    public func setMuted(_ muted: Bool) { pipe?.muted = muted }

    public var stats: VoiceStats? { pipe?.stats }

    public var videoStats: VideoStats? { videoPipe?.stats }

    /// Куда показывать картинки собеседника и свою. Можно задать до начала разговора.
    public func showVideo(_ sink: VideoSink?) {
        pendingSink = sink
        videoPipe?.sink = sink
    }

    public var cameraOn: Bool { cameraWanted }

    public func setCamera(_ on: Bool) {
        cameraWanted = on
        guard case .live = phase else { return }
        applyCamera()
    }

    public func switchCamera() { camera?.switchCamera() }

    private func applyCamera() {
        guard let videoPipe else { return }
        if cameraWanted, camera == nil, let made = env.makeCamera() {
            do {
                try made.start(videoPipe)
                camera = made
            } catch {
                cameraWanted = false
            }
        } else if !cameraWanted, let camera {
            camera.stop()
            self.camera = nil
        }
        videoPipe.cameraOn = cameraWanted && camera != nil
    }

    private func connect(_ secret: CallSecret) {
        let outbox = outbox
        pipe = VoicePipe(secret: secret) { packet in outbox.current?.send(packet) }
        videoPipe = VideoPipe(secret: secret, send: { packet in outbox.current?.send(packet) },
                              backlog: { outbox.current?.backlog ?? 0 })
        videoPipe?.sink = pendingSink
        guard pipe != nil else {
            Task { await finish(.lost, notify: true) }
            return
        }
        slot = secret.slot
        openLink()
    }

    private func openLink() {
        guard let slot, !phase.isEnded else { return }
        let env = env
        reader?.cancel()
        reader = Task { [weak self] in
            guard let transport = await env.openTransport(slot) else {
                try? await Task.sleep(for: env.retryDelay)
                await self?.linkDropped()
                return
            }
            await self?.attach(transport)
            for await item in transport.inbound {
                guard let self else { break }
                switch item {
                case .packet(let packet): await self.deliver(packet)
                case .peers(let count): await self.peers(count)
                }
            }
            transport.close()
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: env.retryDelay)
            await self?.linkDropped()
        }
    }

    private func attach(_ transport: any CallTransport) {
        guard !phase.isEnded else { return transport.close() }
        outbox.current = transport
    }

    private func deliver(_ packet: Data) {
        if group || packet.first == FrameKind.audio.rawValue { pipe?.receive(packet) } else { videoPipe?.receive(packet) }
        lastHeard = .now
        // Связь вернулась, когда снова пошёл звук, а не когда релей насчитал двоих.
        if lossTimer != nil {
            lossTimer?.cancel()
            lossTimer = nil
        }
    }

    private func peers(_ count: Int) async {
        guard !phase.isEnded else { return }
        if count >= 2 {
            guard phase == .connecting || (group && phase == .calling), let pipe else { return }
            deadline?.cancel()
            let voice = env.makeVoice()
            do {
                try voice.start(pipe)
            } catch {
                return await finish(.lost, notify: true)
            }
            self.voice = voice
            set(.live(since: Date()))
            lastHeard = .now
            watchSilence()
            applyCamera()
        } else if case .live = phase {
            startLossTimer()
        }
    }

    private func linkDropped() {
        guard !phase.isEnded else { return }
        outbox.current = nil
        if case .live = phase { startLossTimer() }
        openLink()
    }

    private func watchSilence() {
        let limit = env.silenceLimit
        watch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: limit / 2)
                await self?.checkSilence(limit)
            }
        }
    }

    private func checkSilence(_ limit: Duration) {
        guard case .live = phase, lossTimer == nil, ContinuousClock.now - lastHeard > limit else { return }
        startLossTimer()
        outbox.current?.close()
        outbox.current = nil
        openLink()
    }

    private func startLossTimer() {
        guard lossTimer == nil else { return }
        let grace = env.lossGrace
        lossTimer = Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled else { return }
            await self?.finish(.lost, notify: true)
        }
    }

    // MARK: Внутреннее

    private func arm(after delay: Duration, _ reason: CallEndReason, notify: Bool) {
        deadline?.cancel()
        deadline = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.finish(reason, notify: notify)
        }
    }

    private func set(_ phase: CallPhase) {
        self.phase = phase
        phaseSink.yield(phase)
    }

    func finish(_ reason: CallEndReason, notify: Bool) async {
        guard !phase.isEnded else { return }
        let before = phase
        set(.ended(reason))
        phaseSink.finish()
        voice?.stop()
        voice = nil
        camera?.stop()
        camera = nil
        videoPipe?.close()
        outbox.current?.close()
        outbox.current = nil
        // Конец часто объявляет сам таймер или чтец: гасим их после отправки, иначе отмена оборвёт и её.
        if notify, !group {
            try? await env.post(.end(callID: callID, reason: reason), roomID)
        } else if notify {
            if joined { try? await env.post(.leave(callID: callID, deviceID: env.deviceID), roomID) }
            // Начавший ушёл, пока никто не пришёл: у остальных гаснет будильник.
            if before == .calling { try? await env.post(.end(callID: callID, reason: reason), roomID) }
        }
        deadline?.cancel()
        lossTimer?.cancel()
        watch?.cancel()
        reader?.cancel()
    }
}

/// Участник группового звонка.
public struct CallMember: Sendable, Equatable {
    public let user: String
    public let deviceID: String
    let key: Data
    let tag: UInt32
}

/// Текущий канал: в него пишет поток захвата звука, меняет его звонок при переподключении.
private final class Outbox: Sendable {
    private let slot = Mutex<(any CallTransport)?>(nil)

    var current: (any CallTransport)? {
        get { slot.withLock { $0 } }
        set { slot.withLock { $0 = newValue } }
    }
}
