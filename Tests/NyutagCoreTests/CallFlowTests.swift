import Foundation
@testable import NyutagCore
import Synchronization
import Testing

/// Ход звонка: два диспетчера в одной комнате, релей и звук подменены, кадры настоящие (Opus + шифр).
@Suite struct CallFlowTests {
    static let room = "!call:nyutag.chat"
    static let alice = "@alice:nyutag.chat"
    static let bob = "@bob:nyutag.chat"

    @Test func callIsAnsweredAndVoiceFlows() async throws {
        let line = Line()
        let alice = line.center(Self.alice, "A1"), bob = line.center(Self.bob, "B1")
        let call = try #require(await alice.dial(roomID: Self.room, peer: Self.bob))
        let incoming = try #require(await first(bob.incoming))
        #expect(incoming.callID == call.callID && incoming.peer == Self.alice && !incoming.isCaller)
        #expect(await incoming.phase == .ringing)
        await incoming.accept()
        try await waitLive(call)
        try await waitLive(incoming)
        // Звук ходит в обе стороны и доходит до динамика не тишиной.
        try await until {
            let heard = await incoming.stats?.outputLevel ?? 0
            let back = await call.stats?.outputLevel ?? 0
            return heard > 0.05 && back > 0.05
        }
        // Отдельный ключ на звонок: релей видит только шифр, свой слот у звонка.
        #expect(line.relay.slotsSeen == 1)
        #expect(line.relay.plaintextLeaked == false)
        await call.hangUp()
        #expect(await call.phase == .ended(.hangUp))
        try await until { await incoming.phase == .ended(.hangUp) }
        #expect(line.relay.openLinks == 0)
    }

    @Test func declinedAndUnanswered() async throws {
        let line = Line()
        let alice = line.center(Self.alice, "A1"), bob = line.center(Self.bob, "B1")
        let call = try #require(await alice.dial(roomID: Self.room, peer: Self.bob))
        await try #require(await first(bob.incoming)).hangUp()
        try await until { await call.phase == .ended(.declined) }

        line.ringTimeout = .milliseconds(300)
        let quick = line.center(Self.alice, "A2")
        let unanswered = try #require(await quick.dial(roomID: Self.room, peer: Self.bob))
        try await until { await unanswered.phase == .ended(.noAnswer) }
        #expect(line.posted.contains { if case .end(unanswered.callID, .noAnswer) = $0 { true } else { false } })
    }

    @Test func secondCallGetsBusy() async throws {
        let line = Line()
        let alice = line.center(Self.alice, "A1"), bob = line.center(Self.bob, "B1")
        // Кэрол звонит Бобу из другой комнаты: первого будильника она не видела.
        let other = "!other:nyutag.chat"
        let carol = line.center("@carol:nyutag.chat", "C1", rooms: [other])
        _ = line.center(Self.bob, "B1", rooms: [other], sharing: bob)
        let first = try #require(await alice.dial(roomID: Self.room, peer: Self.bob))
        await try #require(await Self.first(bob.incoming)).accept()
        try await waitLive(first)
        let second = try #require(await carol.dial(roomID: other, peer: Self.bob))
        try await until { await second.phase == .ended(.busy) }
        // У Боба первый разговор не тронут, и второй экран не поднимался.
        #expect(await first.phase.isEnded == false)
        await first.hangUp()
    }

    @Test func answeredOnAnotherDeviceStopsRinging() async throws {
        let line = Line()
        let alice = line.center(Self.alice, "A1")
        let phone = line.center(Self.bob, "B1"), pad = line.center(Self.bob, "B2")
        let call = try #require(await alice.dial(roomID: Self.room, peer: Self.bob))
        let onPhone = try #require(await first(phone.incoming))
        let onPad = try #require(await first(pad.incoming))
        await onPhone.accept()
        try await until { await onPad.phase == .ended(.elsewhere) }
        try await waitLive(call)
        await call.hangUp()
    }

    @Test func oldRingFromFirstSyncIsIgnored() async throws {
        let line = Line()
        let bob = line.center(Self.bob, "B1")
        let ring = CallSignal.ring(callID: CallID.make(), video: false, lifetime: .seconds(45))
        await bob.absorb(CallMessage(signal: ring, roomID: Self.room, sender: Self.alice,
                                     timestamp: Int(Date().timeIntervalSince1970 * 1000) - 120_000))
        #expect(await bob.active() == nil)
    }

    @Test func shortRelayDropIsSurvived() async throws {
        let line = Line()
        let alice = line.center(Self.alice, "A1"), bob = line.center(Self.bob, "B1")
        let call = try #require(await alice.dial(roomID: Self.room, peer: Self.bob))
        let incoming = try #require(await first(bob.incoming))
        await incoming.accept()
        try await waitLive(call)
        let before = await incoming.stats?.received ?? 0
        line.relay.dropAll()
        try await until { (await incoming.stats?.received ?? 0) > before + 20 }
        #expect(await call.phase.isEnded == false)
        await call.hangUp()
    }

    @Test func silentPeerEndsCallAsLost() async throws {
        let line = Line()
        line.silenceLimit = .milliseconds(300)
        line.lossGrace = .milliseconds(600)
        let alice = line.center(Self.alice, "A1"), bob = line.center(Self.bob, "B1")
        let call = try #require(await alice.dial(roomID: Self.room, peer: Self.bob))
        let incoming = try #require(await first(bob.incoming))
        await incoming.accept()
        try await waitLive(call)
        // Каналы повисли: релей держит обе стороны, но кадры больше не идут.
        line.relay.stall()
        try await until { await call.phase == .ended(.lost) }
    }

    // MARK: Помощники

    static func first(_ stream: AsyncStream<CallSession>) async -> CallSession? {
        for await session in stream { return session }
        return nil
    }

    func first(_ stream: AsyncStream<CallSession>) async -> CallSession? { await Self.first(stream) }

    func waitLive(_ session: CallSession) async throws {
        try await until { if case .live = await session.phase { true } else { false } }
    }

    func until(_ timeout: Duration = .seconds(5), _ condition: () async -> Bool) async throws {
        let clock = ContinuousClock(), end = clock.now + timeout
        while clock.now < end {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("не дождались")
    }
}

/// Комната и релей на двоих (и больше) в памяти. Сигналы доходят до всех диспетчеров, включая отправителя (эхо).
final class Line: @unchecked Sendable {
    let relay = FakeRelay()
    private let lock = NSLock()
    private var centers: [(center: CallCenter, rooms: Set<String>)] = []
    private var signals: [CallSignal] = []
    var ringTimeout: Duration = .seconds(45)
    var silenceLimit: Duration = .seconds(5)
    var lossGrace: Duration = .seconds(20)

    var posted: [CallSignal] { lock.withLock { signals } }

    /// `sharing` — тот же диспетчер, но ещё и участник других комнат.
    @discardableResult
    func center(_ user: String, _ device: String, rooms: Set<String> = [CallFlowTests.room],
                sharing: CallCenter? = nil) -> CallCenter {
        if let sharing {
            lock.withLock { centers.append((sharing, rooms)) }
            return sharing
        }
        let relay = relay
        var env = CallEnvironment(me: user, deviceID: device,
            post: { [weak self] signal, room in await self?.deliver(signal, room: room, from: user) },
            openTransport: { slot in relay.join(slot) },
            makeVoice: { ToneVoice() })
        env.ringTimeout = ringTimeout
        env.retryDelay = .milliseconds(50)
        env.silenceLimit = silenceLimit
        env.lossGrace = lossGrace
        let center = CallCenter(env)
        lock.withLock { centers.append((center, rooms)) }
        return center
    }

    private func deliver(_ signal: CallSignal, room: String, from sender: String) async {
        let everyone = lock.withLock { () -> [CallCenter] in
            signals.append(signal)
            return centers.filter { $0.rooms.contains(room) }.map(\.center)
        }
        let message = CallMessage(signal: signal, roomID: room, sender: sender, eventID: "$\(UUID().uuidString)",
                                  timestamp: Int(Date().timeIntervalSince1970 * 1000))
        for center in everyone { await center.absorb(message) }
    }
}

final class FakeRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [String: [FakeLink]] = [:]
    private var seen: Set<String> = []
    private(set) var plaintextLeaked = false
    private var stalled = false

    var slotsSeen: Int { lock.withLock { seen.count } }
    var openLinks: Int { lock.withLock { slots.values.reduce(0) { $0 + $1.count } } }

    func join(_ slot: String) -> FakeLink {
        let link = FakeLink(relay: self, slot: slot)
        let members = lock.withLock { () -> [FakeLink] in
            seen.insert(slot)
            slots[slot, default: []].append(link)
            return slots[slot] ?? []
        }
        for member in members { member.push(.peers(members.count)) }
        return link
    }

    func forward(_ packet: Data, from link: FakeLink) {
        // Голосовой кадр Opus без шифра был бы ~80 байт без метки; шифр всегда добавляет 21 байт заголовка и метки.
        if packet.count < 21 { lock.withLock { plaintextLeaked = true } }
        let others = lock.withLock { stalled ? [] : slots[link.slot]?.filter { $0 !== link } ?? [] }
        for other in others { other.push(.packet(packet)) }
    }

    func leave(_ link: FakeLink) {
        let rest = lock.withLock { () -> [FakeLink] in
            slots[link.slot]?.removeAll { $0 === link }
            return slots[link.slot] ?? []
        }
        for member in rest { member.push(.peers(rest.count)) }
    }

    /// Связи живы, но кадры не идут: так выглядит повисший канал собеседника.
    func stall() { lock.withLock { stalled = true } }

    /// Релей перезапустился: все связи рвутся.
    func dropAll() {
        let all = lock.withLock { slots.values.flatMap { $0 } }
        for link in all { link.close() }
    }
}

final class FakeLink: CallTransport, @unchecked Sendable {
    let slot: String
    let inbound: AsyncStream<RelayInbound>
    private let sink: AsyncStream<RelayInbound>.Continuation
    private weak var relay: FakeRelay?
    private let closed = Atomic<Bool>(false)

    init(relay: FakeRelay, slot: String) {
        self.relay = relay
        self.slot = slot
        (inbound, sink) = AsyncStream.makeStream(of: RelayInbound.self, bufferingPolicy: .bufferingNewest(256))
    }

    func push(_ item: RelayInbound) { sink.yield(item) }
    func send(_ packet: Data) { if !closed.load(ordering: .relaxed) { relay?.forward(packet, from: self) } }

    func close() {
        guard !closed.exchange(true, ordering: .relaxed) else { return }
        relay?.leave(self)
        sink.finish()
    }
}

/// Вместо микрофона — тон 440 Гц, вместо динамика — счётчик: тянет кадры в темпе 20 мс, как звуковая карта.
final class ToneVoice: VoiceIO, @unchecked Sendable {
    private var task: Task<Void, Never>?
    /// NYUTAG_CALL_SILENT — тишина вместо тона (ночные проверки с телефоном владельца).
    private let amplitude: Float = ProcessInfo.processInfo.environment["NYUTAG_CALL_SILENT"] == nil ? 0.3 : 0

    func start(_ pipe: VoicePipe) throws {
        let amplitude = amplitude
        task = Task.detached {
            var phase: Float = 0
            var tone = [Float](repeating: 0, count: VoiceFormat.frameSamples)
            var out = [Float](repeating: 0, count: VoiceFormat.frameSamples)
            while !Task.isCancelled {
                for i in tone.indices {
                    tone[i] = amplitude * sin(phase)
                    phase += 2 * .pi * 440 / Float(VoiceFormat.sampleRate)
                }
                tone.withUnsafeBufferPointer { pipe.capture($0) }
                out.withUnsafeMutableBufferPointer { pipe.render($0) }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    func stop() { task?.cancel() }
}
