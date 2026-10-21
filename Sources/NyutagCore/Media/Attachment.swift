// Нютаг. Вложение реплики (m.image, m.file, m.video, m.audio): откуда качать, как называется, какого размера.
// В зашифрованной комнате адрес и ключ лежат в `file`, в открытой — адрес в `url`. Миниатюра — по тем же правилам
// в `info.thumbnail_file` или `info.thumbnail_url`.

import Foundation

public struct Attachment: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        case plain(MXC)
        case sealed(EncryptedFile)
    }

    /// m.image, m.file, m.video или m.audio.
    public let msgtype: String
    public let source: Source
    public let thumbnail: Source?
    /// Имя файла: `filename`, а если его нет — `body`.
    public let name: String
    public let mimetype: String?
    public let size: Int?
    public let width: Int?
    public let height: Int?
    /// Исчезающее фото: метка `chat.nyutag.view_once` в содержимом, формат общий с Android.
    public let viewOnce: Bool
    /// Длительность видео или звука, мс.
    public let duration: Int?

    /// Миниатюра к отправке: своя картинка (JPEG) по тем же правилам шифрования, что и сам файл.
    public struct Preview: Sendable, Equatable {
        public let source: Source
        public let mimetype: String
        public let size: Int
        public let width: Int?
        public let height: Int?

        public init(source: Source, mimetype: String = "image/jpeg", size: Int, width: Int? = nil, height: Int? = nil) {
            self.source = source
            self.mimetype = mimetype
            self.size = size
            self.width = width
            self.height = height
        }
    }

    public static let viewOnceKey = "chat.nyutag.view_once"

    public init(msgtype: String = "m.file", source: Source, thumbnail: Source? = nil, name: String, mimetype: String? = nil,
                size: Int? = nil, width: Int? = nil, height: Int? = nil, viewOnce: Bool = false, duration: Int? = nil) {
        self.msgtype = msgtype
        self.source = source
        self.thumbnail = thumbnail
        self.name = name
        self.mimetype = mimetype
        self.size = size
        self.width = width
        self.height = height
        self.viewOnce = viewOnce
        self.duration = duration
    }

    /// Вложение из содержимого реплики; у текста и у битого содержимого — `nil`.
    public static func read(_ content: JSONValue) -> Attachment? {
        guard let msgtype = content["msgtype"]?.string, kinds.contains(msgtype),
              let source = locate(file: content["file"], url: content["url"]) else { return nil }
        let info = content["info"]
        let name = content["filename"]?.string ?? content["body"]?.string ?? ""
        return Attachment(msgtype: msgtype, source: source, thumbnail: locate(file: info?["thumbnail_file"], url: info?["thumbnail_url"]),
                          name: name, mimetype: info?["mimetype"]?.string, size: info?["size"]?.int,
                          width: info?["w"]?.int, height: info?["h"]?.int,
                          viewOnce: content[viewOnceKey]?.bool == true, duration: info?["duration"]?.int)
    }

    /// Содержимое реплики с вложением. `body` — имя файла: старые клиенты покажут хотя бы его.
    /// У видео — миниатюра (`thumbnail_file` или `thumbnail_url` c `thumbnail_info`) и длительность в мс.
    public static func content(_ source: Source, name: String, mimetype: String, size: Int,
                               width: Int? = nil, height: Int? = nil, viewOnce: Bool = false,
                               preview: Preview? = nil, duration: Int? = nil) -> JSONValue {
        var info: [String: JSONValue] = ["mimetype": .string(mimetype), "size": .int(size)]
        if let width, let height {
            info["w"] = .int(width)
            info["h"] = .int(height)
        }
        if let duration { info["duration"] = .int(duration) }
        if let preview {
            var thumbInfo: [String: JSONValue] = ["mimetype": .string(preview.mimetype), "size": .int(preview.size)]
            if let w = preview.width, let h = preview.height {
                thumbInfo["w"] = .int(w)
                thumbInfo["h"] = .int(h)
            }
            info["thumbnail_info"] = .object(thumbInfo)
            switch preview.source {
            case .plain(let mxc): info["thumbnail_url"] = .string(mxc.description)
            case .sealed(let file): info["thumbnail_file"] = try? JSONValue(data: JSONEncoder().encode(file))
            }
        }
        var content: [String: JSONValue] = ["msgtype": .string(msgtype(for: mimetype)), "body": .string(name),
                                            "filename": .string(name), "info": .object(info)]
        if viewOnce { content[viewOnceKey] = true }
        switch source {
        case .plain(let mxc): content["url"] = .string(mxc.description)
        case .sealed(let file): content["file"] = try? JSONValue(data: JSONEncoder().encode(file))
        }
        return .object(content)
    }

    /// Вид реплики по типу файла.
    public static func msgtype(for mimetype: String) -> String {
        if mimetype.hasPrefix("image/") { return "m.image" }
        if mimetype.hasPrefix("video/") { return "m.video" }
        if mimetype.hasPrefix("audio/") { return "m.audio" }
        return "m.file"
    }

    /// Картинка, которую показываем в пузыре. GIF и SVG — как файлы: первый кадр и чужой рендер обманули бы.
    public var isImage: Bool {
        msgtype == "m.image" && !["image/gif", "image/svg+xml"].contains(mimetype ?? "")
    }

    /// Видео в пузыре: миниатюра со значком воспроизведения, по нажатию — проигрыватель.
    public var isVideo: Bool { msgtype == "m.video" }

    static let kinds: Set<String> = ["m.image", "m.file", "m.video", "m.audio"]

    static func locate(file: JSONValue?, url: JSONValue?) -> Source? {
        if let file, let data = try? file.data(), let sealed = try? JSONDecoder().decode(EncryptedFile.self, from: data),
           sealed.mxc != nil {
            return .sealed(sealed)
        }
        return url?.string.flatMap(MXC.init).map(Source.plain)
    }
}
