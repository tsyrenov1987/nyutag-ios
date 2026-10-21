// Нютаг. Голосовые: запись (AAC в m4a, моно 24 кГц), волна по уровням громкости, проигрывание в пузыре.
// Одновременно играет одно голосовое; нажатие на другое останавливает первое.

import AVFoundation
import NyutagCore
import SwiftUI

/// Запись голосового. Не больше пяти минут; короче секунды не отправляем — это случайное нажатие.
@MainActor @Observable
final class VoiceRecorder {
    static let limit: TimeInterval = 300
    static let shortest: TimeInterval = 1

    private(set) var recording = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var levels: [Float] = []
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var url: URL?

    nonisolated static var settings: [String: Any] { [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000,
    ] }

    /// `false` — нет разрешения на микрофон или запись не пошла.
    func start() async -> Bool {
        guard !recording, await AVAudioApplication.requestRecordPermission() else { return false }
        VoicePlayer.shared.stop()
        let audio = AVAudioSession.sharedInstance()
        let url = FileManager.default.temporaryDirectory.appending(path: "voice-\(UUID().uuidString).m4a")
        do {
            try audio.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try audio.setActive(true)
            let recorder = try AVAudioRecorder(url: url, settings: Self.settings)
            recorder.isMeteringEnabled = true
            guard recorder.record(forDuration: Self.limit) else { return false }
            self.recorder = recorder
        } catch {
            return false
        }
        self.url = url
        levels = []
        elapsed = 0
        recording = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        return true
    }

    private func tick() {
        guard let recorder, recorder.isRecording else { return }
        recorder.updateMeters()
        levels.append(recorder.averagePower(forChannel: 0))
        elapsed = recorder.currentTime
    }

    /// Готовый к отправке файл; `nil` — слишком коротко или не записалось.
    func finish() -> OutgoingFile? {
        guard let recorder, let url else { return nil }
        let duration = recorder.isRecording ? recorder.currentTime : elapsed
        recorder.stop()
        defer { reset(url) }
        guard duration >= Self.shortest, let data = try? Data(contentsOf: url) else { return nil }
        return OutgoingFile.voice(data, duration: duration, levels: levels)
    }

    func cancel() {
        recorder?.stop()
        if let url { reset(url) }
    }

    private func reset(_ url: URL) {
        timer?.invalidate()
        timer = nil
        recorder = nil
        self.url = nil
        recording = false
        try? FileManager.default.removeItem(at: url)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

extension OutgoingFile {
    static func voice(_ data: Data, duration: TimeInterval, levels: [Float]) -> OutgoingFile {
        var file = OutgoingFile(data: data, name: "voice-\(Int(Date.now.timeIntervalSince1970)).m4a", mimetype: "audio/mp4")
        file.duration = Int((duration * 1000).rounded())
        file.voice = Voice.waveform(decibels: levels)
        return file
    }
}

/// Проигрыватель голосовых: одно за раз, позиция для волны в пузыре.
@MainActor @Observable
final class VoicePlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = VoicePlayer()

    private(set) var current: String?
    private(set) var loading: String?
    private(set) var position: TimeInterval = 0
    private(set) var length: TimeInterval = 0
    private var player: AVAudioPlayer?
    private var timer: Timer?

    var progress: Double { length > 0 ? min(position / length, 1) : 0 }

    func toggle(_ id: String, load: () async -> Data?) async {
        if current == id, let player {
            if player.isPlaying { player.pause() } else { player.play() }
            return
        }
        stop()
        loading = id
        defer { if loading == id { loading = nil } }
        guard let data = await load(), loading == id else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            guard player.play() else { return }
            self.player = player
        } catch {
            #if DEBUG
            print("ui-check: голосовое не играет: \(error)")
            #endif
            return
        }
        current = id
        length = player?.duration ?? 0
        position = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let player = self.player else { return }
                self.position = player.currentTime
            }
        }
    }

    var isPlaying: Bool { player?.isPlaying == true }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        current = nil
        position = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}

/// Голосовое в пузыре: кнопка, волна с прогрессом, время.
struct VoiceChip: View {
    @Environment(AppSession.self) private var session
    @Environment(Words.self) private var words
    let id: String
    let attachment: Attachment
    let ink: Color
    let soft: Color

    private var player: VoicePlayer { VoicePlayer.shared }
    private var mine: Bool { player.current == id }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                Task { await player.toggle(id) { await session.attachmentData(attachment, preview: false) } }
            } label: {
                ZStack {
                    Circle().fill(ink.opacity(0.16))
                    if player.loading == id {
                        ProgressView().tint(ink)
                    } else {
                        Image(systemName: mine && player.isPlaying ? "pause.fill" : "play.fill").foregroundStyle(ink)
                    }
                }
                .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(words(.audio))
            .accessibilityIdentifier("voice-\(id)")
            VStack(alignment: .leading, spacing: 3) {
                Waveform(values: Voice.display(attachment.waveform, bars: 32), progress: mine ? player.progress : 0, ink: ink, soft: soft)
                    .frame(width: 150, height: 26)
                Text(Voice.clock(mine ? Int(player.position * 1000) : attachment.duration ?? 0))
                    .font(.caption).monospacedDigit().foregroundStyle(soft)
            }
        }
    }
}

struct Waveform: View {
    let values: [Double]
    var progress: Double = 0
    let ink: Color
    let soft: Color

    var body: some View {
        GeometryReader { box in
            let step = box.size.width / CGFloat(max(values.count, 1))
            HStack(alignment: .center, spacing: step * 0.35) {
                ForEach(values.indices, id: \.self) { index in
                    Capsule()
                        .fill(Double(index) / Double(max(values.count, 1)) < progress ? ink : soft.opacity(0.55))
                        .frame(width: step * 0.65, height: max(box.size.height * values[index], 3))
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

/// Полоса записи вместо поля ввода: точка, время, живая волна, отмена и отправка.
struct RecordingBar: View {
    @Environment(Words.self) private var words
    let recorder: VoiceRecorder
    let cancel: () -> Void
    let send: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: cancel) {
                Image(systemName: "trash").font(.title3).foregroundStyle(.red).frame(width: 36, height: 40)
            }
            .accessibilityLabel(words(.voiceCancel))
            .accessibilityIdentifier("voice-cancel")
            Circle().fill(.red).frame(width: 9, height: 9)
                .opacity(Int(recorder.elapsed * 2) % 2 == 0 ? 1 : 0.3)
            Text(Voice.clock(Int(recorder.elapsed * 1000))).font(.callout).monospacedDigit().foregroundStyle(Theme.ink)
            Waveform(values: Voice.display(Voice.waveform(decibels: Array(recorder.levels.suffix(60)), bars: 30), bars: 30),
                     ink: Theme.sky, soft: Theme.sky)
                .frame(height: 24)
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.bold))
                    .foregroundStyle(Theme.onGold)
                    .frame(width: 40, height: 40)
                    .background(Theme.gold, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .accessibilityLabel(words(.send))
            .accessibilityIdentifier("voice-send")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }
}

#if DEBUG
/// Для самопроверки на симуляторе без микрофона: три секунды тона с «речевой» огибающей, в m4a.
enum VoiceSample {
    static func make() -> OutgoingFile? {
        let rate = 24_000.0
        let seconds = 3.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * seconds)) else { return nil }
        buffer.frameLength = buffer.frameCapacity
        var levels: [Float] = []
        for frame in 0..<Int(buffer.frameLength) {
            let t = Double(frame) / rate
            let envelope = 0.5 + 0.5 * sin(2 * .pi * 1.3 * t)
            buffer.floatChannelData![0][frame] = Float(envelope * 0.4 * sin(2 * .pi * 220 * t))
            if frame % 1200 == 0 { levels.append(Float(20 * log10(max(envelope * 0.4, 0.0001)))) }
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "voice-sample.m4a")
        try? FileManager.default.removeItem(at: url)
        do {
            let file = try AVAudioFile(forWriting: url, settings: VoiceRecorder.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        } catch {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return OutgoingFile.voice(data, duration: seconds, levels: levels)
    }
}
#endif
