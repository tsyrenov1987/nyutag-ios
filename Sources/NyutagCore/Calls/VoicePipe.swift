// Нютаг. Конвейер голоса одного звонка. Три потока: захват (микрофон → Opus → шифр → релей), сеть (кадр → шифр →
// буфер дрожания) и воспроизведение (буфер → Opus → динамик). Воспроизведение тянет кадры само, в темпе звуковой
// карты, поэтому часы отправителя и получателя не расходятся: лишнее срезает буфер дрожания.

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
    private struct Shared {
        var sealer: CallCipher
        var jitter = JitterBuffer()
        var stats = VoiceStats()
        var muted = false
    }

    private let shared: Mutex<Shared>
    private let opener: CallCipher
    private let encoder: VoiceEncoder
    private let decoder: VoiceDecoder
    private let send: @Sendable (Data) -> Void
    /// Только поток захвата.
    private var pending: [Float] = []
    /// Только поток воспроизведения.
    private var playing: [Float] = []
    private var playIndex = 0
    private let silence = [Float](repeating: 0, count: VoiceFormat.frameSamples)

    public init?(secret: CallSecret, send: @escaping @Sendable (Data) -> Void) {
        guard let encoder = VoiceEncoder(), let decoder = VoiceDecoder() else { return nil }
        shared = Mutex(Shared(sealer: CallCipher(secret)))
        opener = CallCipher(secret)
        self.encoder = encoder
        self.decoder = decoder
        self.send = send
        pending.reserveCapacity(VoiceFormat.frameSamples * 4)
    }

    public var muted: Bool {
        get { shared.withLock { $0.muted } }
        set { shared.withLock { $0.muted = newValue } }
    }

    public var stats: VoiceStats {
        shared.withLock { state in
            var stats = state.stats
            stats.played = state.jitter.played
            stats.lost = state.jitter.lost
            return stats
        }
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
            if let packet { send(packet) }
        }
    }

    /// Кадр из релея. Чужие и подделанные отбрасываются.
    public func receive(_ packet: Data) {
        guard let frame = opener.open(packet), frame.kind == .audio else { return }
        shared.withLock { state in
            state.stats.received += 1
            state.jitter.insert(frame.sequence, frame.payload)
        }
    }

    /// Воспроизведение: заполнить буфер звуковой карты.
    public func render(_ out: UnsafeMutableBufferPointer<Float>) {
        var filled = 0
        while filled < out.count {
            if playIndex >= playing.count {
                let pull = shared.withLock { $0.jitter.pull() }
                switch pull {
                case .frame(let packet):
                    let decoded = decoder.decode(packet)
                    playing = decoded.isEmpty ? silence : decoded
                    let level = Self.rms(playing)
                    shared.withLock { $0.stats.outputLevel = level }
                case .missing, .waiting:
                    playing = silence
                }
                playIndex = 0
            }
            let count = min(out.count - filled, playing.count - playIndex)
            for i in 0..<count { out[filled + i] = playing[playIndex + i] }
            filled += count
            playIndex += count
        }
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
    }
}
