// Нютаг. Волна голосового: уровни громкости записи (дБ, как отдаёт AVAudioRecorder) → до сотни столбиков 0…1024.

import Foundation

public enum Voice {
    public static let bars = 100
    /// Тише этого — тишина, громче нуля не бывает.
    static let floor: Float = -50

    /// Уровни в дБ (0 — максимум) раз в несколько десятков мс. Больше `bars` — усредняем соседние.
    public static func waveform(decibels: [Float], bars: Int = bars) -> [Int] {
        guard !decibels.isEmpty, bars > 0 else { return [] }
        let levels = decibels.map { db -> Float in
            guard db.isFinite else { return 0 }
            return (min(max(db, floor), 0) - floor) / -floor
        }
        let count = min(bars, levels.count)
        return (0..<count).map { bar in
            let from = bar * levels.count / count
            let to = max((bar + 1) * levels.count / count, from + 1)
            let mean = levels[from..<to].reduce(0, +) / Float(to - from)
            return Int((mean * 1024).rounded())
        }
    }

    /// Волна под заданное число столбиков на экране: 0…1, пустая — ровная низкая.
    public static func display(_ waveform: [Int], bars: Int) -> [Double] {
        guard bars > 0 else { return [] }
        guard !waveform.isEmpty else { return Array(repeating: 0.15, count: bars) }
        return (0..<bars).map { bar in
            let index = min(bar * waveform.count / bars, waveform.count - 1)
            return max(Double(waveform[index]) / 1024, 0.08)
        }
    }

    /// «0:07», «1:23».
    public static func clock(_ milliseconds: Int) -> String {
        let seconds = max(milliseconds, 0) / 1000
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
}
