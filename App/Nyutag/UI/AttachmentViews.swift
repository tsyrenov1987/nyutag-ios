// Нютаг. Вложения в чате: картинка в пузыре по своим пропорциям, плашка файла с именем и размером,
// подготовка снимка к отправке (пережать до 2560 px в JPEG — заодно уходят геометка и прочие EXIF).

import ImageIO
import NyutagCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
        let drawn = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let jpeg = drawn.jpegData(compressionQuality: 0.82) else { return nil }
        return OutgoingFile(data: jpeg, name: name + ".jpg", mimetype: "image/jpeg",
                            width: Int(target.width), height: Int(target.height))
    }

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
                Image(systemName: "photo.badge.exclamationmark").font(.title2).foregroundStyle(Theme.quiet)
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
