// Нютаг. Конвейер голоса одного звонка. Три потока: захват (микрофон → Opus → шифр → релей), сеть (кадр → шифр →
// буфер дрожания) и воспроизведение (буфер → Opus → динамик). Воспроизведение тянет кадры само, в темпе звуковой
// карты, поэтому часы отправителя и получателя не расходятся: лишнее срезает буфер дрожания.
// В групповом звонке у каждого участника свой буфер и декодер, при воспроизведении голоса складываются.

import Foundation
import Synchronization

public struct VoiceStats: Sendable, Equatable {
    public var sent = 0
    public var received = 0
    public var played = 0
    public var lost = 0
    /// Громкость последнего кадра, 0…1 (RMS).
    public var inputLevel: Float = 0
    public var outputLevel: Float = 0
}

/// Источник и приёмник звука: микрофон с динамиком телефона или подделка в тестах.
public protocol VoiceIO: AnyObject, Sendable {
    func start(_ pipe: VoicePipe) throws
    func stop()
}

public final class VoicePipe: @unchecked Sendable {
    /// Голос одного собеседника: свой шифр, буфер дрожания и декодер. Декодер и `playing` — только поток
    /// воспроизведения.
    private final class Track: @unchecked Sendable {
        let opener: CallCipher
        let jitter = Mutex(JitterBuffer())
        let received = Atomic<Int>(0)
        let decoder: VoiceDecoder
        var playing: [Float] = []
        var playIndex = 0

        init?(_ secret: CallSecret) {
            guard let decoder = VoiceDecoder() else { return nil }
            opener = CallCipher(secret)
            self.decoder = decoder
        }
    }

    private struct Shared {
        var sealer: CallCipher
        var stats = VoiceStats()
        var muted = false
    }

    /// Метка своих кадров в групповом звонке: релей раздаёт кадры всем, по метке получатель находит ключ.
    /// В звонке один на один меток нет.
    private let tag: UInt32?
    private let shared: Mutex<Shared>
    private let tracks: Mutex<[UInt32: Track]>
    private let encoder: VoiceEncoder
    private let send: @Sendable (Data) -> Void
    /// Только поток захвата.
    private var pending: [Float] = []
    /// Только поток воспроизведения.
    private var mix: [Float] = []
    private let silence = [Float](repeating: 0, count: VoiceFormat.frameSamples)

    public convenience init?(secret: CallSecret, send: @escaping @Sendable (Data) -> Void) {
        guard let track = Track(secret) else { return nil }
        self.init(tag: nil, sealer: secret, tracks: [0: track], send: send)
    }

    /// Групповой звонок: свои кадры шифруем своим ключом и метим `tag`, голоса участников добавляет `add`.
    public convenience init?(group secret: CallSecret, tag: UInt32, send: @escaping @Sendable (Data) -> Void) {
        self.init(tag: tag, sealer: secret, tracks: [:], send: send)
    }

    private init?(tag: UInt32?, sealer: CallSecret, tracks: [UInt32: Track], send: @escaping @Sendable (Data) -> Void) {
        guard let encoder = VoiceEncoder() else { return nil }
        self.tag = tag
        shared = Mutex(Shared(sealer: CallCipher(sealer)))
        self.tracks = Mutex(tracks)
        self.encoder = encoder
        self.send = send
        pending.reserveCapacity(VoiceFormat.frameSamples * 4)
    }

    /// Участник группового звонка: его кадры с меткой `tag` открываются `secret`.
    public func add(tag: UInt32, secret: CallSecret) {
        guard self.tag != nil, let track = Track(secret) else { return }
        tracks.withLock { $0[tag] = track }
    }

    public func remove(tag: UInt32) {
        tracks.withLock { $0[tag] = nil }
    }

    public var voices: Int { tracks.withLock { $0.count } }

    public var muted: Bool {
        get { shared.withLock { $0.muted } }
        set { shared.withLock { $0.muted = newValue } }
    }

    public var stats: VoiceStats {
        var stats = shared.withLock { $0.stats }
        for track in tracks.withLock({ Array($0.values) }) {
            stats.received += track.received.load(ordering: .relaxed)
            track.jitter.withLock {
                stats.played += $0.played
                stats.lost += $0.lost
            }
        }
        return stats
    }

    /// Захват: отсчёты 48 кГц моно любой длины. Без звука (микрофон выключен) шлём тишину: у собеседника не
    /// пустеет буфер, и после включения не надо копить заново.
    public func capture(_ samples: UnsafeBufferPointer<Float>) {
        pending.append(contentsOf: samples)
        while pending.count >= VoiceFormat.frameSamples {
            let muted = shared.withLock { $0.muted }
            let frame = Array(pending.prefix(VoiceFormat.frameSamples))
            pending.removeFirst(VoiceFormat.frameSamples)
            let source = muted ? silence : frame
            guard let encoded = source.withUnsafeBufferPointer({ encoder.encode($0) }) else { continue }
            let level = muted ? 0 : Self.rms(frame)
            let packet = shared.withLock { state -> Data? in
                state.stats.inputLevel = level
                state.stats.sent += 1
                return state.sealer.seal(.audio, encoded)
            }
            guard let packet else { continue }
            if let tag { send(Self.label(tag) + packet) } else { send(packet) }
        }
    }

    /// Кадр из релея. Чужие и подделанные отбрасываются; в групповом звонке впереди метка отправителя.
    public func receive(_ packet: Data) {
        var body = packet
        var key: UInt32 = 0
        if tag != nil {
            guard let (label, rest) = Self.unlabel(packet) else { return }
            key = label
            body = rest
        }
        guard let track = tracks.withLock({ $0[key] }), let frame = track.opener.open(body), frame.kind == .audio else { return }
        track.received.add(1, ordering: .relaxed)
        track.jitter.withLock { $0.insert(frame.sequence, frame.payload) }
    }

    /// Воспроизведение: заполнить буфер звуковой карты. Голоса участников складываются.
    public func render(_ out: UnsafeMutableBufferPointer<Float>) {
        for i in out.indices { out[i] = 0 }
        let playing = tracks.withLock { Array($0.values) }
        if mix.count < out.count { mix = [Float](repeating: 0, count: out.count) }
        var level: Float = 0
        for track in playing {
            level = max(level, fill(track, out.count))
            for i in out.indices { out[i] += mix[i] }
        }
        if playing.count > 1 {
            for i in out.indices { out[i] = min(max(out[i], -1), 1) }
        }
        shared.withLock { $0.stats.outputLevel = level }
    }

    /// Следующие `count` отсчётов голоса в `mix`. Возвращает громкость последнего декодированного кадра.
    private func fill(_ track: Track, _ count: Int) -> Float {
        var filled = 0
        var level: Float = track.playing.isEmpty ? 0 : Self.rms(track.playing)
        while filled < count {
            if track.playIndex >= track.playing.count {
                switch track.jitter.withLock({ $0.pull() }) {
                case .frame(let packet):
                    let decoded = track.decoder.decode(packet)
                    track.playing = decoded.isEmpty ? silence : decoded
                case .missing, .waiting:
                    track.playing = silence
                }
                track.playIndex = 0
                level = Self.rms(track.playing)
            }
            let n = min(count - filled, track.playing.count - track.playIndex)
            for i in 0..<n { mix[filled + i] = track.playing[track.playIndex + i] }
            filled += n
            track.playIndex += n
        }
        return level
    }

    static func label(_ tag: UInt32) -> Data {
        withUnsafeBytes(of: tag.bigEndian) { Data($0) }
    }

    static func unlabel(_ packet: Data) -> (UInt32, Data)? {
        guard packet.count > 4 else { return nil }
        let tag = packet.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return (tag, packet.dropFirst(4))
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
    }
}
