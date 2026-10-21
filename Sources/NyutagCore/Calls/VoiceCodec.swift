// Нютаг. Голос: Opus из AudioToolbox (системный кодек iOS/macOS) через AVAudioConverter.
// 48 кГц, моно, кадр 20 мс = 960 отсчётов, около 80 байт при 32 кбит/с.

import AVFoundation

public enum VoiceFormat {
    public static let sampleRate = 48_000.0
    public static let frameSamples = 960
    public static let bitRate = 32_000

    /// Звук внутри звонка: float32 моно.
    public static let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1,
                                          interleaved: false)!

    static func opus() -> AVAudioFormat? {
        var description = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
                                                      mBytesPerPacket: 0, mFramesPerPacket: UInt32(frameSamples),
                                                      mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0,
                                                      mReserved: 0)
        return AVAudioFormat(streamDescription: &description)
    }
}

/// Не потокобезопасен: один кодировщик на поток захвата.
public final class VoiceEncoder: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let opus: AVAudioFormat
    private let input: AVAudioPCMBuffer

    public init?() {
        guard let opus = VoiceFormat.opus(), let converter = AVAudioConverter(from: VoiceFormat.pcm, to: opus),
              let input = AVAudioPCMBuffer(pcmFormat: VoiceFormat.pcm, frameCapacity: AVAudioFrameCount(VoiceFormat.frameSamples))
        else { return nil }
        converter.bitRate = VoiceFormat.bitRate
        self.converter = converter
        self.opus = opus
        self.input = input
    }

    /// Ровно 960 отсчётов на входе.
    public func encode(_ samples: UnsafeBufferPointer<Float>) -> Data? {
        guard samples.count == VoiceFormat.frameSamples, let channel = input.floatChannelData?[0] else { return nil }
        channel.update(from: samples.baseAddress!, count: samples.count)
        input.frameLength = AVAudioFrameCount(samples.count)
        let output = AVAudioCompressedBuffer(format: opus, packetCapacity: 1, maximumPacketSize: max(converter.maximumOutputPacketSize, 1500))
        var fed = false
        let input = input
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if fed { state.pointee = .noDataNow; return nil }
            fed = true
            state.pointee = .haveData
            return input
        }
        guard status != .error, output.packetCount > 0, output.byteLength > 0 else { return nil }
        return Data(bytes: output.data, count: Int(output.byteLength))
    }
}

public final class VoiceDecoder: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let opus: AVAudioFormat
    private let output: AVAudioPCMBuffer

    public init?() {
        guard let opus = VoiceFormat.opus(), let converter = AVAudioConverter(from: opus, to: VoiceFormat.pcm),
              let output = AVAudioPCMBuffer(pcmFormat: VoiceFormat.pcm, frameCapacity: AVAudioFrameCount(VoiceFormat.frameSamples * 2))
        else { return nil }
        self.converter = converter
        self.opus = opus
        self.output = output
    }

    /// Отсчёты одного кадра; битый кадр — пустой массив.
    public func decode(_ packet: Data) -> [Float] {
        let input = AVAudioCompressedBuffer(format: opus, packetCapacity: 1, maximumPacketSize: packet.count)
        packet.withUnsafeBytes { input.data.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
        input.byteLength = UInt32(packet.count)
        input.packetCount = 1
        input.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                         mDataByteSize: UInt32(packet.count))
        output.frameLength = 0
        var fed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if fed { state.pointee = .noDataNow; return nil }
            fed = true
            state.pointee = .haveData
            return input
        }
        guard status != .error, let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
