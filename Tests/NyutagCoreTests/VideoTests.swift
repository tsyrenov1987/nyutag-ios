import CoreMedia
import CoreVideo
import Foundation
@testable import NyutagCore
import Synchronization
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
