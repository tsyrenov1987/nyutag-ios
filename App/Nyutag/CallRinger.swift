// Нютаг. Звонок через систему: PushKit будит приложение VoIP-пушем шлюза, CallKit показывает входящий поверх
// блокировки и ведёт звук (сессию звука включает система). Сам звонок ведёт стойка CallDesk; здесь только перевод
// между ней и системой: кнопки CallKit → стойка, фазы звонка → CallKit.

import AVFAudio
import CallKit
import NyutagCore
import PushKit

@MainActor
final class CallRinger: NSObject {
    static let shared = CallRinger()

    /// Будильник из VoIP-пуша: приложение поднимает вход и отдаёт его стойке.
    var onRing: ((CallMessage) -> Void)?
    /// Новый токен PushKit: его записывают вторым пушером.
    var onToken: ((Data) -> Void)?
    private(set) var voipToken: Data?

    weak var desk: CallDesk?
    private let provider: CXProvider
    private let controller = CXCallController()
    private var registry: PKPushRegistry?
    private var uuids: [String: UUID] = [:]
    /// Входящие, о которых система уже знает (из пуша или из ленты).
    private var reported: Set<String> = []
    /// Приняли или отклонили на экране CallKit раньше, чем звонок дошёл до стойки: пуш быстрее синхронизации.
    private var answerWhenReady: Set<String> = []
    private var endWhenReady: Set<String> = []
    /// Положили трубку кнопкой CallKit: система уже знает, что звонок закончен.
    private var endedHere: Set<String> = []

    private override init() {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]
        configuration.includesCallsInRecents = true
        provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    /// При каждом запуске: без реестра PushKit iOS не отдаёт VoIP-пуши.
    func start() {
        guard registry == nil else { return }
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.registry = registry
    }

    // MARK: Стойка → система

    /// Стойка показала звонок: исходящий заводим в CallKit, входящий из ленты (пуша не было) — сообщаем.
    func track(_ session: CallSession) {
        let id = session.callID
        let uuid = uuid(for: id)
        if session.isCaller {
            let start = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: session.peer))
            start.isVideo = session.video
            controller.request(CXTransaction(action: start)) { error in
                #if DEBUG
                if let error { print("ui-check: CallKit не завёл исходящий: \(error.localizedDescription)") }
                #endif
            }
            return
        }
        if !reported.contains(id) {
            reportIncoming(id, uuid: uuid, handle: session.peer, name: desk?.peerName, video: session.video)
        }
        if endWhenReady.remove(id) != nil {
            endedHere.insert(id)
            Task { await session.hangUp() }
        } else if answerWhenReady.remove(id) != nil {
            Task { await desk?.performAccept(id) }
        }
    }

    /// Фаза звонка — системе: время соединения исходящего и конец звонка.
    func follow(_ phase: CallPhase, of session: CallSession) {
        let id = session.callID
        guard let uuid = uuids[id] else { return }
        switch phase {
        case .connecting where session.isCaller:
            provider.reportOutgoingCall(with: uuid, startedConnectingAt: Date())
        case .live where session.isCaller:
            provider.reportOutgoingCall(with: uuid, connectedAt: Date())
        case .ended(let reason):
            if endedHere.remove(id) == nil {
                provider.reportCall(with: uuid, endedAt: Date(), reason: Self.systemReason(reason))
            }
            forget(id)
        default:
            break
        }
    }

    /// Кнопки нашего экрана идут через CallKit, чтобы система знала о звонке то же, что и мы.
    func answer(_ callID: String) {
        guard let uuid = uuids[callID] else { return fallback { await self.desk?.performAccept(callID) } }
        controller.request(CXTransaction(action: CXAnswerCallAction(call: uuid))) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in await self?.desk?.performAccept(callID) }
        }
    }

    func end(_ callID: String) {
        guard let uuid = uuids[callID] else { return fallback { await self.desk?.performHangUp(callID) } }
        controller.request(CXTransaction(action: CXEndCallAction(call: uuid))) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in await self?.desk?.performHangUp(callID) }
        }
    }

    func setMuted(_ muted: Bool, _ callID: String) {
        guard let uuid = uuids[callID] else { return }
        controller.request(CXTransaction(action: CXSetMutedCallAction(call: uuid, muted: muted))) { _ in }
    }

    private func fallback(_ work: @escaping @MainActor () async -> Void) {
        Task { await work() }
    }

    // MARK: Вспомогательное

    private func uuid(for callID: String) -> UUID {
        if let known = uuids[callID] { return known }
        let made = UUID()
        uuids[callID] = made
        return made
    }

    private func callID(for uuid: UUID) -> String? {
        uuids.first { $0.value == uuid }?.key
    }

    private func forget(_ callID: String) {
        uuids[callID] = nil
        reported.remove(callID)
        answerWhenReady.remove(callID)
        endWhenReady.remove(callID)
    }

    private func reportIncoming(_ id: String, uuid: UUID, handle: String, name: String?, video: Bool) {
        reported.insert(id)
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: handle)
        update.localizedCallerName = name
        update.hasVideo = video
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        provider.reportNewIncomingCall(with: uuid, update: update) { error in
            #if DEBUG
            print("ui-check: CallKit входящий \(id.prefix(6)): \(error.map { "ошибка \($0.localizedDescription)" } ?? "показан")")
            #endif
        }
    }

    static func systemReason(_ reason: CallEndReason) -> CXCallEndedReason {
        switch reason {
        case .hangUp, .declined: .remoteEnded
        case .noAnswer: .unanswered
        case .busy, .lost: .failed
        case .elsewhere: .answeredElsewhere
        }
    }

    /// Звук разговора: категорию ставим сами, включает и выключает сессию система.
    private static func prepareAudio() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
        try? session.setPreferredSampleRate(VoiceFormat.sampleRate)
        try? session.setPreferredIOBufferDuration(0.01)
    }

    // MARK: Пуш

    fileprivate func incoming(_ ring: CallMessage?, caller: String?) {
        guard let ring else {
            // На каждый VoIP-пуш iOS требует показать звонок, иначе перестанет их доставлять: непонятный
            // показываем и сразу закрываем.
            let uuid = UUID()
            provider.reportNewIncomingCall(with: uuid, update: CXCallUpdate()) { _ in }
            provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
            return
        }
        let id = ring.signal.callID
        let uuid = uuid(for: id)
        let video = if case .ring(_, let video, _) = ring.signal { video } else { false }
        reportIncoming(id, uuid: uuid, handle: ring.sender, name: caller, video: video)
        guard ring.isRinging() else {
            // Пуш опоздал: звонок уже кончился.
            provider.reportCall(with: uuid, endedAt: Date(), reason: .unanswered)
            return forget(id)
        }
        #if DEBUG
        print("ui-check: VoIP-пуш звонка \(id.prefix(6)) из \(ring.roomID.prefix(8))…")
        #endif
        onRing?(ring)
        // Вход не поднялся или звонок не дошёл до стойки: не оставляем экран звонка висеть.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, self.uuids[id] == uuid, self.desk?.current?.callID != id else { return }
            self.provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
            self.forget(id)
        }
    }

    fileprivate func updated(_ token: Data) {
        voipToken = token
        onToken?(token)
    }
}

extension CallRinger: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        MainActor.assumeIsolated {
            let desk = desk
            Task { await desk?.hangUp() }
            uuids = [:]
            reported = []
            answerWhenReady = []
            endWhenReady = []
            endedHere = []
        }
    }

    // Действие CallKit не Sendable: внутрь главного потока передаём только его UUID, исполняем снаружи.
    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        let uuid = action.callUUID
        MainActor.assumeIsolated {
            Self.prepareAudio()
            self.provider.reportOutgoingCall(with: uuid, startedConnectingAt: nil)
        }
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        let uuid = action.callUUID
        let known = MainActor.assumeIsolated { () -> Bool in
            guard let id = callID(for: uuid) else { return false }
            Self.prepareAudio()
            if desk?.current?.callID == id {
                let desk = desk
                Task { await desk?.performAccept(id) }
            } else {
                answerWhenReady.insert(id)
            }
            return true
        }
        if known { action.fulfill() } else { action.fail() }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        let uuid = action.callUUID
        MainActor.assumeIsolated {
            guard let id = callID(for: uuid) else { return }
            endedHere.insert(id)
            if desk?.current?.callID == id {
                let desk = desk
                Task { await desk?.performHangUp(id) }
            } else {
                endWhenReady.insert(id)
            }
        }
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        let uuid = action.callUUID, muted = action.isMuted
        MainActor.assumeIsolated {
            if let id = callID(for: uuid), desk?.current?.callID == id, desk?.muted != muted {
                desk?.muted = muted
            }
        }
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        #if DEBUG
        print("ui-check: CallKit включил звук")
        #endif
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {}
}

extension CallRinger: PKPushRegistryDelegate {
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials,
                                  for type: PKPushType) {
        let token = pushCredentials.token
        MainActor.assumeIsolated { updated(token) }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
                                  for type: PKPushType, completion: @escaping () -> Void) {
        let dictionary = payload.dictionaryPayload
        let ring = ApplePusher.ring(in: dictionary), caller = ApplePusher.ringCaller(in: dictionary)
        MainActor.assumeIsolated { incoming(ring, caller: caller) }
        completion()
    }
}
