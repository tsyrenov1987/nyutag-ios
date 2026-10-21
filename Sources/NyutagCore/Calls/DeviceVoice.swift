// Нютаг. Микрофон и динамик устройства для звонка: AVAudioEngine с системным шумо- и эхоподавлением
// (voice processing). Входной формат микрофона приводим к 48 кГц моно, выход — узел-источник, который тянет
// отсчёты из конвейера.

import AVFoundation

public final class DeviceVoice: VoiceIO, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private let lock = NSLock()
    /// С CallKit сессию звука включает система (provider didActivate), сами её не трогаем.
    private let managesSession: Bool
    private var watchers: [NSObjectProtocol] = []
    /// Журнал отладки: перезапуски движка и их причины.
    private let log: @Sendable (String) -> Void

    public init(managesSession: Bool = true, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.managesSession = managesSession
        self.log = log
    }

    /// Движок работает (для журнала отладки).
    public var isRunning: Bool { engine.isRunning }

    public func start(_ pipe: VoicePipe) throws {
        lock.lock()
        defer { lock.unlock() }
        #if os(iOS)
        if managesSession {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
            try session.setPreferredSampleRate(VoiceFormat.sampleRate)
            try session.setPreferredIOBufferDuration(0.01)
            try session.setActive(true)
        }
        #endif
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        let inputFormat = input.outputFormat(forBus: 0)
        let target = VoiceFormat.pcm
        let converter = inputFormat == target ? nil : AVAudioConverter(from: inputFormat, to: target)
        input.installTap(onBus: 0, bufferSize: 480, format: inputFormat) { buffer, _ in
            guard let converter else {
                if let channel = buffer.floatChannelData?[0] {
                    pipe.capture(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
                }
                return
            }
            let ratio = target.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, state in
                if fed { state.pointee = .noDataNow; return nil }
                fed = true
                state.pointee = .haveData
                return buffer
            }
            if let channel = converted.floatChannelData?[0], converted.frameLength > 0 {
                pipe.capture(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
            }
        }
        let source = AVAudioSourceNode(format: target) { _, _, frameCount, buffers in
            let list = UnsafeMutableAudioBufferListPointer(buffers)
            guard let first = list.first, let data = first.mData else { return noErr }
            let out = UnsafeMutableBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: Int(frameCount))
            pipe.render(out)
            return noErr
        }
        self.source = source
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: target)
        engine.prepare()
        try engine.start()
        log("звук: движок запущен, вход \(inputFormat.sampleRate) Гц \(inputFormat.channelCount) кан.")
        // Смена маршрута или включение сессии системой (CallKit) останавливает движок: запускаем снова.
        let center = NotificationCenter.default
        watchers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                           queue: nil) { [weak self] _ in self?.revive("смена конфигурации") })
        #if os(iOS)
        watchers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                           queue: nil) { [weak self] note in
            let kind = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            if kind == .ended { self?.revive("конец прерывания") } else { self?.log("звук: прерывание") }
        })
        #endif
    }

    private func revive(_ why: String) {
        lock.lock()
        defer { lock.unlock() }
        guard source != nil, !engine.isRunning else { return log("звук: \(why), движок работает") }
        engine.prepare()
        do {
            try engine.start()
            log("звук: \(why), движок перезапущен")
        } catch {
            log("звук: \(why), перезапуск не удался: \(error)")
        }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        for watcher in watchers { NotificationCenter.default.removeObserver(watcher) }
        watchers = []
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let source { engine.detach(source) }
        source = nil
        #if os(iOS)
        if managesSession { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        #endif
    }

    /// Громкая связь вместо разговорного динамика.
    public static func setSpeaker(_ on: Bool) {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(on ? .speaker : .none)
        #endif
    }
}
