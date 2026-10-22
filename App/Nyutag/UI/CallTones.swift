// Нютаг. Звуки звонящего, как у обычного телефона: длинные гудки, пока у собеседника звенит, и короткие, когда звонок
// оборвался не по нашей кнопке (занято, отклонили, нет ответа, собеседник положил трубку). Тон 425 Гц, ритм как в
// российской телефонной сети: гудок 1 с, пауза 4 с; короткие — по 0,35 с. Звук идёт в сессию звонка, которую
// включает CallKit, поэтому играем только после её включения.

import AVFAudio

@MainActor
final class CallTones {
    static let shared = CallTones()

    private enum Kind { case ringback, ended }

    private var wanted: Kind?
    private var player: AVAudioPlayer?
    private var playing: Kind?
    /// Сессию звука включила система (CallKit) или мы сами без него.
    private var audioReady = false
    private lazy var ringbackSound = Self.wav(beeps: 1, on: 1.0, off: 4.0)
    private lazy var endedSound = Self.wav(beeps: 3, on: 0.35, off: 0.35)

    private init() {}

    /// Длинные гудки, пока не скажут `stop()`.
    func ringback() {
        wanted = .ringback
        play()
    }

    /// Три коротких гудка: звонок закончился не по нашей кнопке.
    func ended() {
        wanted = .ended
        play()
    }

    func stop() {
        wanted = nil
        silence()
    }

    /// CallKit включил сессию звука: если гудки уже просили, начинаем.
    func audioActivated() {
        audioReady = true
        play()
    }

    func audioDeactivated() {
        audioReady = false
        silence()
    }

    private func silence() {
        player?.stop()
        player = nil
        playing = nil
    }

    private func play() {
        guard let wanted, playing != wanted else { return }
        if CallRinger.shared.bypass {
            // Без CallKit (отладка в симуляторе) звук симулятора на главном потоке подвисает на ~30 с и держит
            // приём сигналов, поэтому гудки только отмечаем в логе.
            playing = wanted
            #if DEBUG
            print("ui-check: гудки: \(wanted == .ringback ? "длинные" : "короткие") (без звука)")
            #endif
            return
        }
        guard audioReady else { return }
        silence()
        do {
            let player = try AVAudioPlayer(data: wanted == .ringback ? ringbackSound : endedSound)
            player.numberOfLoops = wanted == .ringback ? -1 : 0
            player.volume = 0.6
            player.play()
            self.player = player
            playing = wanted
            #if DEBUG
            print("ui-check: гудки: \(wanted == .ringback ? "длинные" : "короткие")")
            #endif
        } catch {
            #if DEBUG
            print("ui-check: гудки не включились: \(error.localizedDescription)")
            #endif
        }
    }

    /// WAV (16 бит, моно, 16 кГц): `beeps` раз тон `on` секунд и тишина `off` секунд. Края тона сглажены, без щелчков.
    private static func wav(beeps: Int, on: Double, off: Double) -> Data {
        let rate = 16_000
        let onFrames = Int(on * Double(rate)), period = Int((on + off) * Double(rate)), fade = rate / 100
        let total = period * beeps
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + total * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(rate)); put(UInt32(rate * 2)); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(UInt32(total * 2))
        for i in 0..<total {
            let k = i % period
            guard k < onFrames else { put(Int16(0)); continue }
            let edge = min(1, Double(min(k, onFrames - k)) / Double(fade))
            put(Int16(12_000 * edge * sin(2 * .pi * 425 * Double(k) / Double(rate))))
        }
        return data
    }
}
