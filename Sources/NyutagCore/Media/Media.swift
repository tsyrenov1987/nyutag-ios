// Нютаг. Медиа: адреса mxc://, загрузка на сервер, скачивание и миниатюры через авторизованный
// `/_matrix/client/v1/media`, кэш файлов на диске.

import CryptoKit
import Foundation

/// Адрес `mxc://<сервер>/<id>`.
public struct MXC: Sendable, Hashable, CustomStringConvertible {
    public let server: String
    public let mediaID: String

    public init?(_ string: String) {
        guard string.hasPrefix("mxc://") else { return nil }
        let parts = string.dropFirst("mxc://".count).split(separator: "/", maxSplits: 1)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty, !parts[1].contains("/") else { return nil }
        server = String(parts[0])
        mediaID = String(parts[1])
    }

    public var description: String { "mxc://\(server)/\(mediaID)" }
}

public enum ThumbnailMethod: String, Sendable {
    case crop, scale
}

public extension MatrixClient {
    /// Загрузка файла. Возвращает `content_uri`.
    func uploadMedia(_ data: Data, contentType: String, filename: String? = nil) async throws(MatrixError) -> MXC {
        let query = filename.map { ["filename": $0] } ?? [:]
        let response = try await upload("/_matrix/media/v3/upload", query: query, body: data, contentType: contentType)
        guard let json = try? JSONValue(data: response), let uri = json["content_uri"]?.string, let mxc = MXC(uri) else {
            throw MatrixError(.decoding("upload: нет content_uri"))
        }
        return mxc
    }

    func downloadMedia(_ mxc: MXC) async throws(MatrixError) -> Data {
        try await data(.get, "/_matrix/client/v1/media/download/\(mxc.server)/\(mxc.mediaID)")
    }

    func thumbnail(_ mxc: MXC, width: Int, height: Int,
                   method: ThumbnailMethod = .scale) async throws(MatrixError) -> Data {
        try await data(.get, "/_matrix/client/v1/media/thumbnail/\(mxc.server)/\(mxc.mediaID)",
                       query: ["width": String(width), "height": String(height), "method": method.rawValue])
    }

    /// Лимит размера загрузки (`m.upload.size`), если сервер его сообщает.
    func mediaUploadLimit() async throws(MatrixError) -> Int? {
        let json: JSONValue = try await raw(.get, "/_matrix/client/v1/media/config")
        return json["m.upload.size"]?.int
    }
}

/// Кэш медиа в каталоге (в приложении: Caches общей app group, чтобы NSE видел аватары).
/// Ключ — SHA-256 от адреса и размера миниатюры; файлы старше лимита по объёму вытесняются по дате доступа.
public actor MediaCache {
    public let directory: URL
    public let byteLimit: Int
    private let client: MatrixClient
    private var inFlight: [String: Task<Data, any Error>] = [:]

    public init(client: MatrixClient, directory: URL, byteLimit: Int = 300 * 1024 * 1024) throws {
        self.client = client
        self.directory = directory
        self.byteLimit = byteLimit
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Файл целиком или миниатюра (`size` = ширина и высота). Повторные запросы того же ключа ждут первый.
    public func data(_ mxc: MXC, size: (width: Int, height: Int)? = nil) async throws -> Data {
        let key = Self.key(mxc, size: size)
        let url = directory.appending(path: key)
        if let cached = try? Data(contentsOf: url) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            return cached
        }
        if let running = inFlight[key] { return try await running.value }
        let client = client
        let task = Task<Data, any Error> {
            if let size {
                return try await client.thumbnail(mxc, width: size.width, height: size.height)
            }
            return try await client.downloadMedia(mxc)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let data = try await task.value
        try data.write(to: url, options: .atomic)
        try trim()
        return data
    }

    /// Положить свой только что загруженный файл, чтобы не качать его обратно.
    public func store(_ data: Data, for mxc: MXC) throws {
        try data.write(to: directory.appending(path: Self.key(mxc, size: nil)), options: .atomic)
        try trim()
    }

    public func totalBytes() throws -> Int {
        try files().reduce(0) { $0 + $1.size }
    }

    public func clear() throws {
        for file in try files() { try FileManager.default.removeItem(at: file.url) }
    }

    static func key(_ mxc: MXC, size: (width: Int, height: Int)?) -> String {
        var source = mxc.description
        if let size { source += "#\(size.width)x\(size.height)" }
        return SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func files() throws -> [(url: URL, size: Int, date: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys).map { url in
            let values = try url.resourceValues(forKeys: Set(keys))
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
    }

    private func trim() throws {
        var all = try files()
        var total = all.reduce(0) { $0 + $1.size }
        guard total > byteLimit else { return }
        all.sort { $0.date < $1.date }
        for file in all where total > byteLimit {
            try FileManager.default.removeItem(at: file.url)
            total -= file.size
        }
    }
}
