// Нютаг. Буфер против дрожания сети: кадры приходят неровно и не по порядку, а играть их надо ровно каждые 20 мс.
// Перед началом копим `target` кадров. Дыра — отдаём «потерян» и идём дальше (кодек сгладит). Буфер опустел —
// копим заново: так задержка сама подрастает на плохой сети. Набралось слишком много — выбрасываем старое,
// чтобы собеседник не слышал себя с опозданием в секунду.

import Foundation

public struct JitterBuffer: Sendable {
    public enum Pull: Sendable, Equatable {
        case frame(Data)
        /// Кадр не пришёл вовремя: играть замену.
        case missing
        /// Играть нечего, ждём накопления: тишина.
        case waiting
    }

    public let target: Int
    public let limit: Int
    private var frames: [UInt32: Data] = [:]
    private var next: UInt32?
    /// Всё, что не новее этого номера, уже сыграно или пропущено: опоздавшие кадры не нужны.
    private var floor: UInt32?
    public private(set) var played = 0
    public private(set) var lost = 0
    public private(set) var dropped = 0

    public init(target: Int = 3, limit: Int = 12) {
        self.target = target
        self.limit = limit
    }

    public var depth: Int { frames.count }

    public mutating func insert(_ sequence: UInt32, _ payload: Data) {
        if let next, sequence < next { dropped += 1; return }
        if let floor, sequence <= floor { dropped += 1; return }
        frames[sequence] = payload
        if frames.count > limit, let newest = frames.keys.max() {
            // Догоняем: оставляем последние `target` кадров.
            let keep = newest &- UInt32(target - 1)
            for key in frames.keys where key < keep { frames[key] = nil; dropped += 1 }
            next = keep
            floor = keep &- 1
        }
    }

    public mutating func pull() -> Pull {
        guard let current = next else {
            guard frames.count >= target, let first = frames.keys.min() else { return .waiting }
            next = first
            return pull()
        }
        if let frame = frames.removeValue(forKey: current) {
            next = current &+ 1
            floor = current
            played += 1
            return .frame(frame)
        }
        if frames.isEmpty {
            next = nil
            return .waiting
        }
        floor = current
        next = current &+ 1
        lost += 1
        return .missing
    }
}
