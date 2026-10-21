// Нютаг. Видео: H.264 из VideoToolbox (аппаратный кодек iOS/macOS). Портрет 480×640, до 24 кадров в секунду,
// поток без B-кадров и с ключевым кадром не реже раза в 2 с: потерянное у собеседника лечится следующим ключевым.
//
// Кадр на проводе: [флаги 1 байт: бит 0 — ключевой]; у ключевого дальше [число наборов параметров 1 байт] и каждый
// набор как [длина 2 байта BE][байты] (SPS, PPS); затем единицы NAL в виде AVCC (длина 4 байта BE + байты).

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public enum VideoFormat {
    public static let width = 480
    public static let height = 640
    public static let frameRate = 24
    public static let startBitRate = 600_000
    public static let minBitRate = 150_000
    public static let maxBitRate = 1_000_000
    public static let keyInterval: Double = 2
}

/// Картинка для экрана. Пиксельный буфер передаётся между потоками только для чтения.
public struct VideoPicture: @unchecked Sendable {
    public let buffer: CVPixelBuffer
    /// Отразить при показе: своя фронтальная камера, как в зеркале.
    public let mirrored: Bool

    public init(buffer: CVPixelBuffer, mirrored: Bool = false) {
        self.buffer = buffer
        self.mirrored = mirrored
    }

    public var width: Int { CVPixelBufferGetWidth(buffer) }
    public var height: Int { CVPixelBufferGetHeight(buffer) }
}

public struct VideoFrame: Sendable, Equatable {
    public var keyframe: Bool
    /// SPS и PPS; только у ключевого.
    public var parameterSets: [Data]
    /// Единицы NAL в виде AVCC.
    public var units: Data

    public var wire: Data {
        var out = Data([keyframe ? 1 : 0])
        if keyframe {
            out.append(UInt8(parameterSets.count))
            for set in parameterSets {
                out.append(UInt8(set.count >> 8))
                out.append(UInt8(set.count & 0xFF))
                out.append(set)
            }
        }
        out.append(units)
        return out
    }

    public init(keyframe: Bool, parameterSets: [Data], units: Data) {
        self.keyframe = keyframe
        self.parameterSets = parameterSets
        self.units = units
    }

    public init?(wire: Data) {
        let bytes = [UInt8](wire)
        guard let flags = bytes.first else { return nil }
        keyframe = flags & 1 == 1
        var at = 1
        parameterSets = []
        if keyframe {
            guard at < bytes.count else { return nil }
            let count = Int(bytes[at])
            at += 1
            for _ in 0..<count {
                guard at + 2 <= bytes.count else { return nil }
                let length = Int(bytes[at]) << 8 | Int(bytes[at + 1])
                at += 2
                guard length > 0, at + length <= bytes.count else { return nil }
                parameterSets.append(Data(bytes[at..<(at + length)]))
                at += length
            }
            guard parameterSets.count >= 2 else { return nil }
        }
        guard at < bytes.count else { return nil }
        units = Data(bytes[at...])
    }
}

/// Кодировщик одного звонка. Кадры с камеры подаются из одного потока, готовые приходят в `output` из потока
/// VideoToolbox.
public final class VideoEncoder: @unchecked Sendable {
    private let lock = NSLock()
    private var session: VTCompressionSession?
    private var size: (width: Int, height: Int) = (0, 0)
    private var forceKey = true
    private var bitRate = VideoFormat.startBitRate
    private let output: @Sendable (VideoFrame) -> Void

    public init(output: @escaping @Sendable (VideoFrame) -> Void) {
        self.output = output
    }

    deinit { invalidate() }

    public func encode(_ buffer: CVPixelBuffer, time: CMTime) {
        lock.lock()
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        if session == nil || size != (width, height) {
            if let session { VTCompressionSessionInvalidate(session) }
            session = Self.makeSession(width: width, height: height, bitRate: bitRate)
            size = (width, height)
            forceKey = true
        }
        guard let session else { return lock.unlock() }
        let properties: CFDictionary? = forceKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        forceKey = false
        lock.unlock()
        let output = output
        VTCompressionSessionEncodeFrame(session, imageBuffer: buffer, presentationTimeStamp: time, duration: .invalid,
                                        frameProperties: properties, infoFlagsOut: nil) { status, _, sample in
            guard status == noErr, let sample, let frame = Self.frame(from: sample) else { return }
            output(frame)
        }
    }

    /// Собеседник потерял кадр: следующий — ключевой.
    public func requestKeyframe() {
        lock.withLock { forceKey = true }
    }

    public func setBitRate(_ value: Int) {
        lock.withLock {
            bitRate = value
            if let session {
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: value as CFNumber)
            }
        }
    }

    public func invalidate() {
        lock.withLock {
            if let session { VTCompressionSessionInvalidate(session) }
            session = nil
        }
    }

    private static func makeSession(width: Int, height: Int, bitRate: Int) -> VTCompressionSession? {
        // Кодировщик с низкой задержкой есть только у железа: без него (симулятор) — обычный.
        let lowLatency = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
        let made = [lowLatency, nil].lazy.compactMap { specification -> VTCompressionSession? in
            var made: VTCompressionSession?
            guard VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                             codecType: kCMVideoCodecType_H264, encoderSpecification: specification,
                                             imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil,
                                             refcon: nil, compressionSessionOut: &made) == noErr else { return nil }
            return made
        }.first
        guard let session = made else { return nil }
        let settings: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_AverageBitRate: bitRate,
            kVTCompressionPropertyKey_ExpectedFrameRate: VideoFormat.frameRate,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: VideoFormat.keyInterval,
        ]
        for (key, value) in settings { VTSessionSetProperty(session, key: key, value: value as CFTypeRef) }
        VTCompressionSessionPrepareToEncodeFrames(session)
        return session
    }

    static func frame(from sample: CMSampleBuffer) -> VideoFrame? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        var sets: [Data] = []
        if keyframe, let format = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                               nalUnitHeaderLengthOut: nil)
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var length = 0
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &length,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let pointer else { return nil }
                sets.append(Data(bytes: pointer, count: length))
            }
        }
        let length = CMBlockBufferGetDataLength(block)
        var units = Data(count: length)
        let copied = units.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        return VideoFrame(keyframe: keyframe, parameterSets: sets, units: units)
    }
}

/// Декодер одного звонка. Подаётся из одного потока; без ключевого кадра декодировать нечего.
public final class VideoDecoder: @unchecked Sendable {
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var parameterSets: [Data] = []
    private let output: @Sendable (VideoPicture) -> Void

    public init(output: @escaping @Sendable (VideoPicture) -> Void) {
        self.output = output
    }

    deinit { invalidate() }

    /// `false` — кадр не лёг (нет ключевого до него или поток испорчен): нужен ключевой.
    public func decode(_ frame: VideoFrame) -> Bool {
        if frame.keyframe, frame.parameterSets != parameterSets || session == nil {
            guard rebuild(frame.parameterSets) else { return false }
        }
        guard let session, let format, let sample = Self.sample(frame.units, format: format) else { return false }
        let output = output
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
            status, _, image, _, _ in
            guard status == noErr, let image else { return }
            output(VideoPicture(buffer: image))
        }
        return status == noErr
    }

    public func invalidate() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
        parameterSets = []
    }

    private func rebuild(_ sets: [Data]) -> Bool {
        invalidate()
        var made: CMFormatDescription?
        let status = sets.withPointers { pointers, sizes in
            CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: sets.count,
                                                                parameterSetPointers: pointers,
                                                                parameterSetSizes: sizes, nalUnitHeaderLength: 4,
                                                                formatDescriptionOut: &made)
        }
        guard status == noErr, let made else { return false }
        let attributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                          kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        var decoder: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: made, decoderSpecification: nil,
                                           imageBufferAttributes: attributes, outputCallback: nil,
                                           decompressionSessionOut: &decoder) == noErr, let decoder else { return false }
        VTSessionSetProperty(decoder, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = decoder
        format = made
        parameterSets = sets
        return true
    }

    private static func sample(_ units: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: units.count,
                                                 blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: units.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == kCMBlockBufferNoErr, let block else { return nil }
        let copied = units.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                          dataLength: units.count)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        var sample: CMSampleBuffer?
        var size = units.count
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }
}

private extension [Data] {
    /// Указатели на байты наборов параметров на время вызова.
    func withPointers<R>(_ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>) -> R) -> R {
        let copies = map { data -> UnsafeMutablePointer<UInt8> in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
            data.copyBytes(to: pointer, count: data.count)
            return pointer
        }
        defer { copies.forEach { $0.deallocate() } }
        let pointers = copies.map { UnsafePointer($0) }
        let sizes = map(\.count)
        return pointers.withUnsafeBufferPointer { p in sizes.withUnsafeBufferPointer { s in body(p.baseAddress!, s.baseAddress!) } }
    }
}
