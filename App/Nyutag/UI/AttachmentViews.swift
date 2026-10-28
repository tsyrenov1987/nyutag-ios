// Нютаг. Вложения в чате: картинка в пузыре по своим пропорциям, плашка файла с именем и размером,
// подготовка снимка к отправке (пережать до 2560 px в JPEG — заодно уходят геометка и прочие EXIF).

import AVFoundation
import CoreTransferable
import ImageIO
import NyutagCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Ролик из галереи: PhotosPicker отдаёт его файлом, копия живёт во временной папке до отправки.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let copy = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + "." + received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}

/// Снимок или ролик с камеры прямо из скрепки: системная камера, своего интерфейса нет.
/// Ролик приходит файлом во временной папке (хозяин — вызвавший), снимок — JPEG с ориентацией в EXIF.
struct CameraPicker: UIViewControllerRepresentable {
    enum Shot {
        case photo(Data)
        case movie(URL)
    }

    let done: (Shot?) -> Void

    static var available: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
        picker.videoQuality = .typeHigh
        // Дольше трёх минут и 720p не влезет в 25 МБ сервера.
        picker.videoMaximumDuration = 180
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (Shot?) -> Void

        init(done: @escaping (Shot?) -> Void) { self.done = done }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let url = info[.mediaURL] as? URL {
                // Временный файл камеры система уберёт после закрытия, поэтому своя копия.
                let copy = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + "." + url.pathExtension)
                if (try? FileManager.default.copyItem(at: url, to: copy)) != nil { done(.movie(copy)) } else { done(nil) }
            } else if let image = info[.originalImage] as? UIImage, let jpeg = image.jpegData(compressionQuality: 0.95) {
                done(.photo(jpeg))
            } else {
                done(nil)
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { done(nil) }
    }
}

extension OutgoingFile {
    /// Снимок из галереи: длинная сторона не больше 2560 px, JPEG. Ориентация уже применена.
    nonisolated static func photo(_ data: Data, name: String = "photo") -> OutgoingFile? {
        guard let image = UIImage(data: data) else { return nil }
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let scale = min(1, 2560 / max(pixels.width, pixels.height, 1))
        let target = CGSize(width: (pixels.width * scale).rounded(), height: (pixels.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let drawn = UIGraphicsImageRenderer(size: target, format: format).image { context in
            // Прозрачное (стикер, скриншот PNG) ложится на белый, а не на чёрный.
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: target))
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let jpeg = drawn.jpegData(compressionQuality: 0.82) else { return nil }
        return OutgoingFile(data: jpeg, name: name + ".jpg", mimetype: "image/jpeg",
                            width: Int(target.width), height: Int(target.height))
    }

    /// Сервер принимает до 25 МБ за запрос; пережатый до 720p ролик длиннее нескольких минут туда не влезет.
    static let videoLimit = 24 * 1024 * 1024

    /// Ролик: пережать до 1280×720 в MP4 (H.264) — заодно уходят геометка и прочие метаданные, —
    /// снять кадр-миниатюру и длительность. Длиннее лимита — `nil`.
    nonisolated static func video(at url: URL, name: String) async -> OutgoingFile? {
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720) else { return nil }
        let out = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        export.shouldOptimizeForNetworkUse = true
        export.metadataItemFilter = .forSharing()
        do { try await export.export(to: out, as: .mp4) } catch { return nil }
        guard let data = try? Data(contentsOf: out), data.count <= videoLimit else { return nil }
        let exported = AVURLAsset(url: out)
        let seconds = (try? await exported.load(.duration).seconds) ?? 0
        var file = OutgoingFile(data: data, name: name + ".mp4", mimetype: "video/mp4", duration: Int((seconds * 1000).rounded()))
        if let track = try? await exported.loadTracks(withMediaType: .video).first,
           let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
            let box = CGRect(origin: .zero, size: size).applying(transform)
            file.width = Int(abs(box.width).rounded())
            file.height = Int(abs(box.height).rounded())
        }
        let generator = AVAssetImageGenerator(asset: exported)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 800, height: 800)
        let at = CMTime(seconds: min(0.5, seconds / 2), preferredTimescale: 600)
        if let (frame, _) = try? await generator.image(at: at) {
            file.thumbnail = UIImage(cgImage: frame).jpegData(compressionQuality: 0.8)
        }
        return file
    }

    #if DEBUG
    /// Нарисованный ролик для проверок: 2 секунды, 640×360, цвет плывёт по кругу, белый квадрат едет вправо.
    nonisolated static func drawnVideo() async -> URL? {
        let url = FileManager.default.temporaryDirectory.appending(path: "proverka-src.mp4")
        try? FileManager.default.removeItem(at: url)
        let width = 640, height = 360
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return nil }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<20 {
            while !input.isReadyForMoreMediaData { try? await Task.sleep(for: .milliseconds(20)) }
            guard let pool = adaptor.pixelBufferPool else { return nil }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { return nil }
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            context?.setFillColor(UIColor(hue: CGFloat(frame) / 20, saturation: 0.6, brightness: 0.9, alpha: 1).cgColor)
            context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context?.setFillColor(UIColor.white.cgColor)
            context?.fill(CGRect(x: 40 + frame * 24, y: 140, width: 80, height: 80))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed ? url : nil
    }
    #endif

    /// Файл из «Файлов». Тип — по расширению; неизвестный уходит как поток байт.
    nonisolated static func file(at url: URL) -> OutgoingFile? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let type = UTType(filenameExtension: url.pathExtension)
        var file = OutgoingFile(data: data, name: url.lastPathComponent,
                                mimetype: type?.preferredMIMEType ?? "application/octet-stream")
        if type?.conforms(to: .image) == true, let size = ImageMemory.pixelSize(data) {
            file.width = size.width
            file.height = size.height
        }
        return file
    }
}

/// Уменьшенные картинки ленты в памяти: прокрутка не расшифровывает и не раскодирует их заново.
@MainActor
enum ImageMemory {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 120
        return cache
    }()

    static func get(_ key: String) -> UIImage? { cache.object(forKey: key as NSString) }
    static func put(_ image: UIImage, _ key: String) { cache.setObject(image, forKey: key as NSString) }

    /// Раскодировать сразу уменьшенной: полный снимок в 12 Мп занял бы в памяти ~48 МБ.
    nonisolated static func downsample(_ data: Data, maxPixels: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    /// Аватар: квадрат по центру снимка, сторона `side`, JPEG. EXIF с геометкой не переносится.
    nonisolated static func squareJPEG(_ data: Data, side: CGFloat) -> Data? {
        guard let image = downsample(data, maxPixels: Int(side * 2)) else { return nil }
        let short = min(image.size.width, image.size.height)
        guard short > 0 else { return nil }
        let scale = side / short
        let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let square = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            image.draw(in: CGRect(x: (side - drawn.width) / 2, y: (side - drawn.height) / 2,
                                  width: drawn.width, height: drawn.height))
        }
        return square.jpegData(compressionQuality: 0.85)
    }

    nonisolated static func pixelSize(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }
}

/// Картинка в пузыре. Пока грузится — подложка тех же пропорций, чтобы лента не прыгала.
struct AttachmentImage: View {
    @Environment(AppSession.self) private var session
    let key: String
    let attachment: Attachment
    var local: UIImage?

    @State private var image: UIImage?
    @State private var broken = false

    static let width: CGFloat = 240

    var body: some View {
        let shown = local ?? image
        ZStack {
            Rectangle().fill(Theme.plate)
            if let shown {
                Image(uiImage: shown).resizable().scaledToFill()
            } else if broken {
                Image(systemName: attachment.isVideo ? "film" : "photo.badge.exclamationmark").font(.title2).foregroundStyle(Theme.quiet)
            } else {
                ProgressView()
            }
        }
        .frame(width: Self.width, height: Self.height(pixels: (attachment.width, attachment.height), image: shown))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: key) { await load() }
    }

    /// Высота по пропорциям из реплики или самой картинки, в разумных пределах.
    static func height(pixels: (width: Int?, height: Int?), image: UIImage?) -> CGFloat {
        var ratio: CGFloat = 1
        if let w = pixels.width, let h = pixels.height, w > 0, h > 0 {
            ratio = CGFloat(h) / CGFloat(w)
        } else if let image, image.size.width > 0 {
            ratio = image.size.height / image.size.width
        }
        return min(max(width * ratio, 120), 320)
    }

    private func load() async {
        guard local == nil, image == nil else { return }
        if let known = ImageMemory.get(key) { image = known; return }
        guard let data = await session.attachmentData(attachment, preview: true) else { broken = true; return }
        let decoded = await Task.detached(priority: .userInitiated) { ImageMemory.downsample(data, maxPixels: 900) }.value
        guard let decoded else { broken = true; return }
        ImageMemory.put(decoded, key)
        image = decoded
    }
}

/// Поверх миниатюры ролика: значок воспроизведения и длительность в уголке.
struct VideoBadge: View {
    let duration: Int?
    var busy = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.clear
            if busy {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 44)).foregroundStyle(.white.opacity(0.92))
                    .shadow(radius: 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let duration {
                Text(Self.clock(duration))
                    .font(.caption2.monospacedDigit().bold()).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(6)
            }
        }
    }

    /// «0:07», «1:23:05».
    static func clock(_ ms: Int) -> String {
        let total = max(0, ms + 500) / 1000
        let h = total / 3600, m = total % 3600 / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// Плашка файла: значок, имя, размер. Пока файл открывается — крутилка вместо значка.
struct FileChip: View {
    let name: String
    let size: Int?
    let ink: Color
    let soft: Color
    var busy = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(ink.opacity(0.14))
                if busy { ProgressView().tint(ink) } else { Image(systemName: "doc.fill").foregroundStyle(ink) }
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.callout.weight(.medium)).foregroundStyle(ink).lineLimit(2).truncationMode(.middle)
                if let size {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                        .font(.caption).monospacedDigit().foregroundStyle(soft)
                }
            }
        }
        .frame(maxWidth: 240, alignment: .leading)
    }
}

/// Открытые для просмотра файлы: расшифрованная копия живёт во временной папке, пока открыт просмотр.
enum OpenedFiles {
    static var folder: URL { FileManager.default.temporaryDirectory.appending(path: "opened", directoryHint: .isDirectory) }

    static func write(_ data: Data, name: String) -> URL? {
        let dir = folder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let safe = name.replacingOccurrences(of: "/", with: "_")
        let url = dir.appending(path: safe.isEmpty ? "file" : safe)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            return url
        } catch {
            return nil
        }
    }

    static func clear() { try? FileManager.default.removeItem(at: folder) }
}

/// Исчезающие фото, которые мы уже открыли: второй раз не откроются, даже если удаление не дошло до сервера.
/// Запоминаем в момент открытия — переживает закрытие приложения во время просмотра.
@MainActor @Observable
final class ViewOnceSeen {
    static let shared = ViewOnceSeen()
    private static let key = "nyutag.viewOnce.opened"
    private(set) var ids: Set<String>

    private init() { ids = Set(UserDefaults.standard.stringArray(forKey: Self.key) ?? []) }

    func contains(_ eventID: String) -> Bool { ids.contains(eventID) }

    func mark(_ eventID: String) {
        guard ids.insert(eventID).inserted else { return }
        UserDefaults.standard.set(Array(ids.suffix(500)), forKey: Self.key)
    }
}

/// Заглушка исчезающего фото в пузыре: миниатюры нет, открыть можно один раз.
struct ViewOnceChip: View {
    @Environment(Words.self) private var words
    let mine: Bool
    let seen: Bool
    let ink: Color
    let soft: Color
    var busy = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(ink.opacity(0.14))
                if busy {
                    ProgressView().tint(ink)
                } else {
                    Image(systemName: seen ? "flame" : "flame.fill").foregroundStyle(seen ? soft : ink)
                }
            }
            .frame(width: 40, height: 40)
            Text(words(mine ? .viewOnceSent : seen ? .viewOnceOpened : .viewOnceReceived))
                .font(.callout.weight(.medium)).foregroundStyle(seen ? soft : ink)
        }
        .frame(maxWidth: 240, alignment: .leading)
    }
}

/// Фото на слое системного поля пароля: такой слой iOS не кладёт ни в снимок экрана, ни в запись.
/// Если слой найти не удалось (система поменяла устройство поля), показываем фото как обычно.
struct ScreenshotShield: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIView {
        let picture = UIImageView(image: image)
        picture.contentMode = .scaleAspectFit
        let field = UITextField()
        field.isSecureTextEntry = true
        guard let shielded = field.subviews.first else { return picture }
        shielded.subviews.forEach { $0.removeFromSuperview() }
        shielded.removeFromSuperview()
        shielded.isUserInteractionEnabled = false
        picture.translatesAutoresizingMaskIntoConstraints = false
        shielded.addSubview(picture)
        NSLayoutConstraint.activate([
            picture.leadingAnchor.constraint(equalTo: shielded.leadingAnchor),
            picture.trailingAnchor.constraint(equalTo: shielded.trailingAnchor),
            picture.topAnchor.constraint(equalTo: shielded.topAnchor),
            picture.bottomAnchor.constraint(equalTo: shielded.bottomAnchor),
        ])
        #if DEBUG
        print("ui-check: защита от снимка экрана \(type(of: shielded))")
        #endif
        return shielded
    }

    func updateUIView(_ view: UIView, context: Context) {}
}

/// Одноразовый просмотр во весь экран. На снимке экрана фото нет; пока экран записывается или транслируется — тоже.
struct ViewOnceViewer: View {
    let image: UIImage
    let close: () -> Void
    @State private var captured = UIScreen.main.isCaptured

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if captured {
                Image(systemName: "eye.slash").font(.largeTitle).foregroundStyle(.white.opacity(0.6))
            } else {
                ScreenshotShield(image: image).ignoresSafeArea()
            }
        }
        .overlay(alignment: .topTrailing) {
            Button(action: close) {
                Image(systemName: "xmark").font(.title3.bold()).foregroundStyle(.white)
                    .frame(width: 44, height: 44).background(.white.opacity(0.15), in: Circle())
            }
            .padding()
            .accessibilityIdentifier("view-once-close")
        }
        .onTapGesture(perform: close)
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
            captured = UIScreen.main.isCaptured
        }
    }
}
