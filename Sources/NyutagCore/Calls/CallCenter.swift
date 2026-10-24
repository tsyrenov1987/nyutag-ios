// Нютаг. Диспетчер звонков аккаунта: сигналы из ленты → нужный звонок, входящий будильник → экран, второй
// звонок во время разговора → «занято».

import Foundation

public actor CallCenter {
    private let env: CallEnvironment
    private var sessions: [String: CallSession] = [:]
    /// offer, пришедший раньше будильника (шифрованный расшифровался позже открытого или наоборот).
    private var earlyOffers: [String: CallMessage] = [:]
    /// join группового звонка, пришедшие раньше будильника.
    private var earlyJoins: [String: [CallMessage]] = [:]
    public nonisolated let incoming: AsyncStream<CallSession>
    private let incomingSink: AsyncStream<CallSession>.Continuation

    /// Сколько звенеть входящему как минимум, сколько бы будильник ни шёл по чужим часам.
    static let minimumRing: TimeInterval = 30

    public init(_ env: CallEnvironment) {
        self.env = env
        (incoming, incomingSink) = AsyncStream.makeStream(of: CallSession.self, bufferingPolicy: .bufferingNewest(4))
    }

    /// Позвонить. `nil` — уже идёт другой звонок.
    public func dial(roomID: String, peer: String, video: Bool = false) async -> CallSession? {
        guard await active() == nil else { return nil }
        let session = CallSession(callID: CallID.make(), roomID: roomID, peer: peer, isCaller: true, video: video, env: env)
        sessions[session.callID] = session
        await session.dial()
        return session
    }

    /// Групповой звонок в группе (ключи кадров идут шифром комнаты, даже открытой). `nil` — уже идёт другой звонок.
    public func dialGroup(roomID: String) async -> CallSession? {
        guard await active() == nil else { return nil }
        let session = CallSession(callID: CallID.make(), roomID: roomID, peer: roomID, isCaller: true, video: false,
                                  group: true, env: env)
        sessions[session.callID] = session
        await session.dial()
        return session
    }

    /// Текущий незаконченный звонок.
    public func active() async -> CallSession? {
        for (id, session) in sessions {
            if await session.phase.isEnded { sessions[id] = nil } else { return session }
        }
        return nil
    }

    public func absorb(_ message: CallMessage, now: Date = Date()) async {
        let id = message.signal.callID
        if let session = sessions[id] { return await session.handle(message) }
        switch message.signal {
        case .ring(_, let video, let lifetime, let group):
            guard message.sender != env.me, message.isRinging(now: now) else { return }
            // Занятому групповой не звонит: остальные участники разговаривают и без него.
            if group, await active() != nil { return }
            if await active() != nil {
                try? await env.post(.end(callID: id, reason: .busy), message.roomID)
                return
            }
            let session = CallSession(callID: id, roomID: message.roomID, peer: message.sender, isCaller: false,
                                      video: video, group: group, env: env)
            sessions[id] = session
            // Время будильника — по часам звонящего (в пуше) или сервера. Часы телефона могут расходиться
            // на десятки секунд, поэтому звеним не меньше minimumRing: раньше звонок гасит отбой звонящего.
            let started = Date(timeIntervalSince1970: Double(message.timestamp ?? 0) / 1000)
            let span = Double(lifetime.components.seconds)
            let until = max(started.addingTimeInterval(span), now.addingTimeInterval(min(Self.minimumRing, span)))
            await session.ring(until: until)
            if let offer = earlyOffers.removeValue(forKey: id) { await session.handle(offer) }
            for join in earlyJoins.removeValue(forKey: id) ?? [] { await session.handle(join) }
            incomingSink.yield(session)
        case .offer:
            guard message.sender != env.me else { return }
            if earlyOffers.count >= 16, let oldest = earlyOffers.keys.first { earlyOffers[oldest] = nil }
            earlyOffers[id] = message
        case .join:
            if earlyJoins[id] == nil, earlyJoins.count >= 16, let oldest = earlyJoins.keys.first { earlyJoins[oldest] = nil }
            if earlyJoins[id, default: []].count < 32 { earlyJoins[id, default: []].append(message) }
        case .answer, .end, .leave, .ringing:
            break
        }
    }
}
