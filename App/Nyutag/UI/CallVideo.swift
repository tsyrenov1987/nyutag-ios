// Нютаг. Картинка видеозвонка на экране: слой AVSampleBufferDisplayLayer, в который кладём готовые кадры —
// и собеседника из декодера, и свои с камеры. Кадры приходят из потоков кодека; на слой — в главном потоке.

import AVFoundation
import CoreMedia
import NyutagCore
import SwiftUI
import UIKit

@MainActor
final class PictureFeed {
    fileprivate weak var view: PictureLayerView?
    private(set) var lastShown: Date?

    func show(_ picture: VideoPicture) {
        lastShown = Date()
        guard let view, let sample = Self.sample(picture.buffer) else { return }
        view.transform = picture.mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        let renderer = view.display.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
    }

    func clear() {
        lastShown = nil
        view?.display.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    private static func sample(_ buffer: CVPixelBuffer) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer,
                                                           formatDescriptionOut: &format) == noErr, let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: format,
                                                       sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(first, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}

final class PictureLayerView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var display: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

struct PictureView: UIViewRepresentable {
    let feed: PictureFeed

    func makeUIView(context: Context) -> PictureLayerView {
        let view = PictureLayerView()
        view.display.videoGravity = .resizeAspectFill
        view.backgroundColor = .black
        view.clipsToBounds = true
        feed.view = view
        return view
    }

    func updateUIView(_ view: PictureLayerView, context: Context) {
        feed.view = view
    }
}

#if DEBUG
/// Без камеры (симулятор) — движущиеся полосы вместо неё: NYUTAG_UI_FAKE_CAMERA.
final class StripeCamera: VideoSource, @unchecked Sendable {
    private var task: Task<Void, Never>?

    func start(_ pipe: VideoPipe) throws {
        task = Task.detached {
            var i = 0
            while !Task.isCancelled {
                if let picture = Self.picture(i) {
                    pipe.capture(picture, time: CMTime(value: Int64(i), timescale: Int32(VideoFormat.frameRate)), mirrored: true)
                }
                i += 1
                try? await Task.sleep(for: .milliseconds(1000 / VideoFormat.frameRate))
            }
        }
    }

    func stop() { task?.cancel() }

    private static func picture(_ index: Int) -> CVPixelBuffer? {
        var made: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        guard CVPixelBufferCreate(nil, VideoFormat.width, VideoFormat.height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                  attributes, &made) == kCVReturnSuccess, let buffer = made else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0..<2 {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
            let rows = CVPixelBufferGetHeightOfPlane(buffer, plane), stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<rows {
                for x in 0..<stride {
                    bytes[y * stride + x] = plane == 0 ? UInt8(truncatingIfNeeded: (y + index * 6) / 40 % 2 == 0 ? 200 : 60)
                        : UInt8(truncatingIfNeeded: x % 2 == 0 ? 90 : 170)
                }
            }
        }
        return buffer
    }
}
#endif
