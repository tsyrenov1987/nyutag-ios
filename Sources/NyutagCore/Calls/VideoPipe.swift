// Нютаг. Конвейер видео одного звонка. Отправка: камера → H.264 → куски по 6 КБ → шифр → релей. Приём: шифр →
// сборка кадра из кусков → декодер → экран. Видео идёт тем же каналом, что и голос, и не должно его душить:
// пока в канале застряло много байт, новые кадры камеры не кодируются, а битрейт снижается. Пробку дальше по дороге
// (буферы дверей, медленный приём у собеседника) показывает задержка эха зондов (DelayGauge): растёт — битрейт
// снижается, а на самом низком видео встаёт на паузу, пока путь не освободится. Голос при этом идёт.
// Потерянный кусок (релей сбрасывает кадры медленному получателю) ломает цепочку кадров до следующего ключевого:
// получатель просит его служебным кадром, не дожидаясь планового.
//
// Кусок: [номер кадра 2 байта BE][номер куска 1 байт][кусков в кадре 1 байт][байты кадра].
// Служебный: [код 1 байт]: 1 — пришли ключевой кадр, 2 — камера выключена, 3 — зонд [метка 4 байта BE],
// 4 — эхо зонда [та же метка]. Неизвестный код получатель пропускает: старые версии зонды не возвращают.

import CoreMedia
import CoreVideo
import Foundation

public struct VideoStats: Sendable, Equatable {
    public var sentFrames = 0
    public var sentKeyframes = 0
    /// Кадры камеры, не отправленные из-за забитого канала.
    public var skipped = 0
    public var bitRate = VideoFormat.startBitRate
    public var receivedFrames = 0
    public var shownFrames = 0
    /// Кадры, которые пришли не целиком или не легли в декодер.
    public var brokenFrames = 0
    public var keyRequestsSent = 0
    public var keyRequestsReceived = 0
    /// Задержка пути туда и обратно по эху зондов, мс; `nil` — эха не было.
    public var pathDelay: Int?
    /// Видео на паузе из-за пробки на пути к собеседнику.
    public var paused = false
    public var remoteWidth = 0
    public var remoteHeight = 0
}

/// Камера телефона или подделка в тестах. Кадры отдаёт в `pipe.capture`.
public protocol VideoSource: AnyObject, Sendable {
    func start(_ pipe: VideoPipe) throws
    func stop()
    /// Фронтальная ↔ основная.
    func switchCamera()
}

extension VideoSource {
    public func switchCamera() {}
}

/// Куда конвейер отдаёт картинки. Вызывается из потоков кодека и камеры.
public struct VideoSink: Sendable {
    public var remote: @Sendable (VideoPicture) -> Void
    public var local: @Sendable (VideoPicture) -> Void
    public var remoteCameraOff: @Sendable () -> Void

    public init(remote: @escaping @Sendable (VideoPicture) -> Void, local: @escaping @Sendable (VideoPicture) -> Void = { _ in },
                remoteCameraOff: @escaping @Sendable () -> Void = {}) {
        self.remote = remote
        self.local = local
        self.remoteCameraOff = remoteCameraOff
    }
}

public final class VideoPipe: @unchecked Sendable {
    static let chunkSize = 6_000
    /// Столько байт может ждать отправки, прежде чем новые кадры камеры начнут пропускаться.
    static let backlogLimit = 96 << 10

    private enum Control: UInt8 {
        case keyframe = 1
        case cameraOff = 2
        case probe = 3
        case echo = 4
    }

    private struct Outgoing {
        var video: CallCipher
        var control: CallCipher
        var frameNumber: UInt16 = 0
        var cameraOn = false
        var windowStart = ContinuousClock.now
        var windowSkipped = 0
        var gauge = DelayGauge()
        /// Окон подряд на самом низком битрейте с пробкой.
        var jammedAtFloor = 0
        /// Окон подряд со свободным путём, пока видео на паузе.
        var clearWhilePaused = 0
        var paused = false
    }

    private struct Incoming {
        var lastSequence: UInt32?
        var assembling: UInt16?
        var chunks: [Data?] = []
        var needKey = true
        var lastKeyRequest: ContinuousClock.Instant?
    }

    private let outgoing: Mutex<Outgoing>
    private let incoming = Mutex(Incoming())
    private let counters = Mutex(VideoStats())
    private let sinkSlot = Mutex<VideoSink?>(nil)
    private let opener: CallCipher
    private let send: @Sendable (Data) -> Void
    private let backlog: @Sendable () -> Int
    private var encoder: VideoEncoder!
    private var decoder: VideoDecoder!
    private let epoch = ContinuousClock.now

    public init(secret: CallSecret, send: @escaping @Sendable (Data) -> Void, backlog: @escaping @Sendable () -> Int = { 0 }) {
        outgoing = Mutex(Outgoing(video: CallCipher(secret), control: CallCipher(secret)))
        opener = CallCipher(secret)
        self.send = send
        self.backlog = backlog
        encoder = VideoEncoder { [weak self] frame in self?.ship(frame) }
        decoder = VideoDecoder { [weak self] picture in self?.show(picture) }
    }

    public var sink: VideoSink? {
        get { sinkSlot.withLock { $0 } }
        set { sinkSlot.withLock { $0 = newValue } }
    }

    public var stats: VideoStats { counters.withLock { $0 } }

    /// Своя камера включена: кадры уходят собеседнику. Выключили — он узнаёт об этом сразу, а не по тишине.
    public var cameraOn: Bool {
        get { outgoing.withLock { $0.cameraOn } }
        set {
            let changed = outgoing.withLock { state -> Bool in
                defer { state.cameraOn = newValue }
                return state.cameraOn != newValue
            }
            guard changed else { return }
            if newValue {
                encoder.requestKeyframe()
            } else {
                // Служебный кадр может потеряться у релея: дважды.
                sendControl(.cameraOff)
                sendControl(.cameraOff)
            }
        }
    }

    public func close() {
        sink = nil
        encoder.invalidate()
        decoder.invalidate()
    }

    // MARK: Отправка

    /// Кадр камеры. Поток камеры один.
    public func capture(_ buffer: CVPixelBuffer, time: CMTime, mirrored: Bool = false) {
        let now = ContinuousClock.now
        let ms = millis(now)
        let crowded = backlog() > Self.backlogLimit
        let decision = outgoing.withLock { state -> (on: Bool, bitRate: Int?, probe: Data?, paused: Bool, resumed: Bool) in
            guard state.cameraOn else { return (false, nil, nil, false, false) }
            if crowded { state.windowSkipped += 1 }
            var retune: Int?
            var resumed = false
            if now - state.windowStart >= .seconds(1) {
                let current = counters.withLock { $0.bitRate }
                let verdict = state.gauge.verdict(now: ms)
                var next = current
                if state.windowSkipped > 2 || verdict == .jammed {
                    next = max(VideoFormat.minBitRate, current * 7 / 10)
                    state.clearWhilePaused = 0
                    // Самый низкий битрейт не помог: пауза, голосу весь путь.
                    if current == VideoFormat.minBitRate, verdict == .jammed {
                        state.jammedAtFloor += 1
                        if state.jammedAtFloor >= 3 { state.paused = true }
                    }
                } else {
                    state.jammedAtFloor = 0
                    if state.paused {
                        state.clearWhilePaused = verdict == .clear ? state.clearWhilePaused + 1 : 0
                        if state.clearWhilePaused >= 3 {
                            state.paused = false
                            state.clearWhilePaused = 0
                            resumed = true
                        }
                    } else if state.windowSkipped == 0, verdict != .fair {
                        next = min(VideoFormat.maxBitRate, current + 50_000)
                    }
                }
                if next != current { retune = next }
                state.windowStart = now
                state.windowSkipped = 0
                let delay = state.gauge.delay(now: ms).map { Int($0) }, paused = state.paused
                counters.withLock {
                    $0.pathDelay = delay
                    $0.paused = paused
                }
            }
            var probe: Data?
            if let stamp = state.gauge.probe(now: ms) {
                probe = state.control.seal(.control, Data([Control.probe.rawValue]) + Self.bytes(stamp))
            }
            return (true, retune, probe, state.paused, resumed)
        }
        guard decision.on else { return }
        if let probe = decision.probe { send(probe) }
        sink?.local(VideoPicture(buffer: buffer, mirrored: mirrored))
        if let bitRate = decision.bitRate {
            encoder.setBitRate(bitRate)
            counters.withLock { $0.bitRate = bitRate }
        }
        // После паузы у собеседника цепочка кадров порвана: начинаем с ключевого.
        if decision.resumed { encoder.requestKeyframe() }
        guard !crowded, !decision.paused else { return counters.withLock { $0.skipped += 1 } }
        encoder.encode(buffer, time: time)
    }

    private func millis(_ instant: ContinuousClock.Instant) -> Int64 {
        let elapsed = (instant - epoch).components
        return elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
    }

    private static func bytes(_ stamp: UInt32) -> Data {
        Data([UInt8(stamp >> 24), UInt8(stamp >> 16 & 0xFF), UInt8(stamp >> 8 & 0xFF), UInt8(stamp & 0xFF)])
    }

    private static func stamp(_ payload: Data) -> UInt32? {
        let bytes = [UInt8](payload.dropFirst().prefix(4))
        guard bytes.count == 4 else { return nil }
        return bytes.reduce(0) { $0 << 8 | UInt32($1) }
    }

    private func ship(_ frame: VideoFrame) {
        let wire = frame.wire
        let count = (wire.count + Self.chunkSize - 1) / Self.chunkSize
        guard count > 0, count <= 255 else { return }
        outgoing.withLock { state in
            guard state.cameraOn else { return }
            let number = state.frameNumber
            state.frameNumber &+= 1
            for index in 0..<count {
                let start = wire.startIndex + index * Self.chunkSize
                var chunk = Data([UInt8(number >> 8), UInt8(number & 0xFF), UInt8(index), UInt8(count)])
                chunk.append(wire[start..<min(start + Self.chunkSize, wire.endIndex)])
                // Отправка только ставит в очередь: под замком, чтобы куски уходили по порядку номеров.
                if let packet = state.video.seal(.video, chunk) { send(packet) }
            }
        }
        counters.withLock {
            $0.sentFrames += 1
            if frame.keyframe { $0.sentKeyframes += 1 }
        }
    }

    private func sendControl(_ code: Control, _ extra: Data = Data()) {
        let packet = outgoing.withLock { $0.control.seal(.control, Data([code.rawValue]) + extra) }
        if let packet { send(packet) }
    }

    // MARK: Приём

    /// Кадр видео или служебный из релея. Вызывается из одного потока (звонка).
    public func receive(_ packet: Data) {
        guard let opened = opener.open(packet) else { return }
        switch opened.kind {
        case .control:
            switch opened.payload.first.flatMap(Control.init) {
            case .keyframe:
                counters.withLock { $0.keyRequestsReceived += 1 }
                encoder.requestKeyframe()
            case .cameraOff:
                sink?.remoteCameraOff()
            case .probe:
                // Сразу назад: задержка эха и есть мерка пути.
                if let stamp = Self.stamp(opened.payload) { sendControl(.echo, Self.bytes(stamp)) }
            case .echo:
                guard let stamp = Self.stamp(opened.payload) else { break }
                let now = millis(.now)
                outgoing.withLock { $0.gauge.echo(stamp, now: now) }
            case nil:
                break
            }
        case .video:
            take(opened.sequence, opened.payload)
        case .audio:
            break
        }
    }

    private func take(_ sequence: UInt32, _ chunk: Data) {
        let bytes = [UInt8](chunk.prefix(4))
        guard bytes.count == 4, bytes[3] > 0, bytes[2] < bytes[3] else { return }
        let number = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        let index = Int(bytes[2]), count = Int(bytes[3])
        enum Next { case wait, broken, ready(Data) }
        let next = incoming.withLock { state -> Next in
            var broken = false
            if let last = state.lastSequence, sequence != last &+ 1 {
                // Пропал кусок: собираемый кадр не соберётся, и цепочка до него тоже порвана.
                broken = true
                state.needKey = true
            }
            state.lastSequence = sequence
            if state.assembling != number {
                if state.assembling != nil, state.chunks.contains(where: { $0 == nil }) { broken = true; state.needKey = true }
                state.assembling = number
                state.chunks = Array(repeating: nil, count: count)
            }
            guard state.chunks.count == count else { return .broken }
            state.chunks[index] = chunk.dropFirst(4)
            guard !state.chunks.contains(where: { $0 == nil }) else { return broken ? .broken : .wait }
            let wire = state.chunks.reduce(into: Data()) { $0.append($1!) }
            state.assembling = nil
            state.chunks = []
            return .ready(wire)
        }
        switch next {
        case .wait:
            return
        case .broken:
            counters.withLock { $0.brokenFrames += 1 }
            askKeyframe()
        case .ready(let wire):
            guard let frame = VideoFrame(wire: wire) else { return askKeyframe() }
            counters.withLock { $0.receivedFrames += 1 }
            let waiting = incoming.withLock { $0.needKey }
            guard !waiting || frame.keyframe else {
                // Цепочка до этого кадра порвана: без ключевого он не ляжет.
                counters.withLock { $0.brokenFrames += 1 }
                return askKeyframe()
            }
            if decoder.decode(frame) {
                if frame.keyframe { incoming.withLock { $0.needKey = false } }
            } else {
                incoming.withLock { $0.needKey = true }
                counters.withLock { $0.brokenFrames += 1 }
                askKeyframe()
            }
        }
    }

    /// Не чаще двух раз в секунду: ключевой кадр тяжёлый, а просьба могла уже уйти.
    private func askKeyframe() {
        let now = ContinuousClock.now
        let due = incoming.withLock { state -> Bool in
            if let last = state.lastKeyRequest, now - last < .milliseconds(500) { return false }
            state.lastKeyRequest = now
            return true
        }
        guard due else { return }
        counters.withLock { $0.keyRequestsSent += 1 }
        sendControl(.keyframe)
    }

    private func show(_ picture: VideoPicture) {
        counters.withLock {
            $0.shownFrames += 1
            $0.remoteWidth = picture.width
            $0.remoteHeight = picture.height
        }
        sink?.remote(picture)
    }
}
