import CoreMedia
import CoreVideo
import Foundation
@testable import NyutagCore
import Testing

@Suite struct VideoTests {
    @Test func frameWireRoundTrip() throws {
        let key = VideoFrame(keyframe: true, parameterSets: [Data([0x67, 1, 2]), Data([0x68, 3])], units: Data([0, 0, 0, 1, 0x65]))
        #expect(VideoFrame(wire: key.wire) == key)
        let delta = VideoFrame(keyframe: false, parameterSets: [], units: Data([0, 0, 0, 1, 0x41]))
        #expect(VideoFrame(wire: delta.wire) == delta)
        #expect(VideoFrame(wire: Data([1, 2, 0, 1])) == nil)
        #expect(VideoFrame(wire: Data()) == nil)
    }

    @Test func codecRoundTrip() async throws {
        let shown = Mutex<[(Int, Int)]>([])
        let decoder = VideoDecoder { picture in shown.withLock { $0.append((picture.width, picture.height)) } }
        let frames = Mutex<[VideoFrame]>([])
        let encoder = VideoEncoder { frame in frames.withLock { $0.append(frame) } }
        for i in 0..<30 {
            encoder.encode(try PatternCamera.picture(i), time: CMTime(value: Int64(i), timescale: 24))
        }
        try await until { frames.withLock { $0.count } >= 25 }
        let encoded = frames.withLock { $0 }
        #expect(encoded.first?.keyframe == true)
        #expect(encoded.first?.parameterSets.count == 2)
        for frame in encoded { #expect(decoder.decode(try #require(VideoFrame(wire: frame.wire)))) }
        try await until { shown.withLock { $0.count } >= 25 }
        #expect(shown.withLock { $0.first }.map { $0 == (VideoFormat.width, VideoFormat.height) } == true)
        encoder.invalidate()
    }

    /// Две стороны через «релей», который теряет один кусок: получатель просит ключевой кадр и снова видит.
    @Test func lostChunkRecoversWithKeyframe() async throws {
        let secret = try CallKeyPair.pair(callID: "video-loss-test")
        let drop = Atomic<Int>(-1)
        let sent = Atomic<Int>(0)
        let seen = Atomic<Int>(0)
        let box = PipeBox()
        let sender = VideoPipe(secret: secret.caller, send: { packet in
            let n = sent.add(1, ordering: .relaxed).newValue
            if n == drop.load(ordering: .relaxed) { return }
            box.receiver?.receive(packet)
        })
        let receiver = VideoPipe(secret: secret.callee, send: { packet in box.sender?.receive(packet) })
        box.sender = sender
        box.receiver = receiver
        receiver.sink = VideoSink(remote: { _ in seen.add(1, ordering: .relaxed) })
        sender.cameraOn = true
        let camera = PatternCamera()
        try camera.start(sender)
        defer { print("video test: отправитель \(sender.stats), получатель \(receiver.stats), показано \(seen.load(ordering: .relaxed))") }
        try await until { seen.load(ordering: .relaxed) >= 10 }
        // Теряем следующий кусок.
        drop.store(sent.load(ordering: .relaxed) + 1, ordering: .relaxed)
        try await until { receiver.stats.brokenFrames >= 1 }
        let before = seen.load(ordering: .relaxed)
        try await until { seen.load(ordering: .relaxed) >= before + 10 }
        camera.stop()
        #expect(receiver.stats.keyRequestsSent >= 1)
        #expect(sender.stats.keyRequestsReceived >= 1)
        #expect(sender.stats.sentKeyframes >= 2)
        #expect(receiver.stats.remoteWidth == VideoFormat.width)
        sender.close()
        receiver.close()
    }

    /// Забитый канал: кадры камеры пропускаются и битрейт падает, голосу остаётся место.
    @Test func crowdedChannelSkipsFrames() async throws {
        let secret = try CallKeyPair.pair(callID: "video-crowd-test")
        let pipe = VideoPipe(secret: secret.caller, send: { _ in }, backlog: { 1 << 20 })
        pipe.cameraOn = true
        let camera = PatternCamera()
        try camera.start(pipe)
        try await until(seconds: 6) { pipe.stats.bitRate < VideoFormat.startBitRate && pipe.stats.skipped > 10 }
        camera.stop()
        #expect(pipe.stats.sentFrames == 0)
        pipe.close()
    }

    @Test func cameraOffIsAnnounced() async throws {
        let secret = try CallKeyPair.pair(callID: "video-off-test")
        let off = Atomic<Bool>(false)
        let box = PipeBox()
        let sender = VideoPipe(secret: secret.caller, send: { packet in box.receiver?.receive(packet) })
        let receiver = VideoPipe(secret: secret.callee, send: { _ in })
        box.receiver = receiver
        receiver.sink = VideoSink(remote: { _ in }, remoteCameraOff: { off.store(true, ordering: .relaxed) })
        sender.cameraOn = true
        sender.cameraOn = false
        let announced = off.load(ordering: .relaxed)
        #expect(announced)
    }

    @Test func delayGaugeJudgesByEcho() {
        var gauge = DelayGauge()
        // Эха не было (старая версия у собеседника) — судить не о чем.
        let first = gauge.probe(now: 0)
        #expect(first == 0)
        #expect(gauge.probe(now: 100) == nil)
        #expect(gauge.verdict(now: 2_000) == .unknown)
        gauge.echo(0, now: 300)
        #expect(gauge.base == 300)
        #expect(gauge.verdict(now: 400) == .clear)
        // Один зонд потерялся, следующий вернулся: потерянный больше не ждём.
        _ = gauge.probe(now: 500)
        let third = gauge.probe(now: 1_000)
        gauge.echo(try! #require(third), now: 1_350)
        #expect(gauge.verdict(now: 1_400) == .clear)
        // Эхо перестало приходить: возраст зонда растёт — пробка.
        _ = gauge.probe(now: 1_500)
        #expect(gauge.verdict(now: 1_900) == .clear)
        #expect(gauge.verdict(now: 2_200) == .fair)
        #expect(gauge.verdict(now: 2_400) == .jammed)
        // Пришло с большой задержкой — пробка, пока за секунду нет эха быстрее.
        gauge.echo(1_500, now: 2_500)
        #expect(gauge.verdict(now: 2_600) == .jammed)
        let fast = gauge.probe(now: 2_600)
        gauge.echo(try! #require(fast), now: 2_900)
        #expect(gauge.verdict(now: 3_000) == .clear)
        // Чужая метка не считается.
        gauge.echo(12_345, now: 3_100)
        #expect(gauge.base == 300)
    }

    /// Эхо зондов стало опаздывать на 1,5 с: битрейт падает до низа и видео встаёт на паузу; путь освободился —
    /// видео снова идёт, с ключевого кадра. Своя очередь отправки при этом пуста.
    @Test func slowPathPausesVideo() async throws {
        let secret = try CallKeyPair.pair(callID: "video-path-test")
        let lag = Atomic<Int>(0)
        let box = PipeBox()
        let sender = VideoPipe(secret: secret.caller, send: { packet in box.receiver?.receive(packet) })
        let receiver = VideoPipe(secret: secret.callee, send: { packet in
            let wait = lag.load(ordering: .relaxed)
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(wait)) { box.sender?.receive(packet) }
        })
        box.sender = sender
        box.receiver = receiver
        sender.cameraOn = true
        let camera = PatternCamera()
        try camera.start(sender)
        defer { print("path test: \(sender.stats)") }
        try await until(seconds: 4) { sender.stats.pathDelay != nil }
        lag.store(1_500, ordering: .relaxed)
        try await until(seconds: 15) { sender.stats.paused }
        #expect(sender.stats.bitRate == VideoFormat.minBitRate)
        let sent = sender.stats.sentFrames
        try await Task.sleep(for: .seconds(1))
        #expect(sender.stats.sentFrames <= sent + 1)
        let keys = sender.stats.sentKeyframes
        lag.store(0, ordering: .relaxed)
        try await until(seconds: 8) { !sender.stats.paused }
        try await until(seconds: 3) { sender.stats.sentKeyframes > keys }
        camera.stop()
        sender.close()
        receiver.close()
    }

    private func until(seconds: Double = 5, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("не дождались за \(seconds) с")
        throw CancellationError()
    }
}

private final class PipeBox: @unchecked Sendable {
    var sender: VideoPipe?
    var receiver: VideoPipe?
}

extension CallKeyPair {
    /// Ключи обеих сторон одного звонка.
    static func pair(callID: String) throws -> (caller: CallSecret, callee: CallSecret) {
        let a = CallKeyPair(), b = CallKeyPair()
        return (try a.secret(with: b.publicKey, callID: callID, isCaller: true),
                try b.secret(with: a.publicKey, callID: callID, isCaller: false))
    }
}

/// Вместо камеры — движущиеся полосы 480×640, 24 кадра в секунду.
final class PatternCamera: VideoSource, @unchecked Sendable {
    private var task: Task<Void, Never>?

    func start(_ pipe: VideoPipe) throws {
        task = Task.detached {
            var i = 0
            while !Task.isCancelled {
                if let picture = try? Self.picture(i) {
                    pipe.capture(picture, time: CMTime(value: Int64(i), timescale: Int32(VideoFormat.frameRate)))
                }
                i += 1
                try? await Task.sleep(for: .milliseconds(1000 / VideoFormat.frameRate))
            }
        }
    }

    func stop() { task?.cancel() }

    static func picture(_ index: Int) throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        guard CVPixelBufferCreate(nil, VideoFormat.width, VideoFormat.height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                  attributes, &made) == kCVReturnSuccess, let buffer = made else { throw CancellationError() }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0..<2 {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
            let rows = CVPixelBufferGetHeightOfPlane(buffer, plane), stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<rows {
                for x in 0..<stride {
                    bytes[y * stride + x] = plane == 0 ? UInt8(truncatingIfNeeded: (x + y + index * 8) / 4 * 16) : 128
                }
            }
        }
        return buffer
    }
}
