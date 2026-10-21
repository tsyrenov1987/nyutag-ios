import Foundation
@testable import NyutagCore
import Testing

struct MediaTests {
    @Test func parsesMXC() {
        let mxc = MXC("mxc://nyutag.chat/AbC123")
        #expect(mxc?.server == "nyutag.chat")
        #expect(mxc?.mediaID == "AbC123")
        #expect(mxc?.description == "mxc://nyutag.chat/AbC123")
        #expect(MXC("https://nyutag.chat/AbC") == nil)
        #expect(MXC("mxc://nyutag.chat/") == nil)
        #expect(MXC("mxc://nyutag.chat/a/b") == nil)
    }

    @Test func cacheKeysDifferBySize() {
        let mxc = MXC("mxc://x/y")!
        let full = MediaCache.key(mxc, size: nil)
        #expect(full.count == 64)
        #expect(full != MediaCache.key(mxc, size: (96, 96)))
        #expect(MediaCache.key(mxc, size: (96, 96)) != MediaCache.key(mxc, size: (320, 320)))
    }

    @Test func cacheEvictsOldestOverLimit() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "nyutag-media-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try MediaCache(client: MatrixClient(homeserver: URL(string: "http://127.0.0.1:9")!),
                                   directory: dir, byteLimit: 250)
        try await cache.store(Data(repeating: 1, count: 100), for: MXC("mxc://x/a")!)
        try await cache.store(Data(repeating: 2, count: 100), for: MXC("mxc://x/b")!)
        #expect(try await cache.totalBytes() == 200)
        try await cache.store(Data(repeating: 3, count: 100), for: MXC("mxc://x/c")!)
        #expect(try await cache.totalBytes() <= 250)
        // Свежее берётся из кэша без сети (сервер по адресу :9 не отвечает).
        let c = try await cache.data(MXC("mxc://x/c")!)
        #expect(c.first == 3)
    }

    @Test func attachmentRoundTrip() throws {
        let sealed = try EncryptedFile.encrypt(Data("снимок".utf8), url: "mxc://nyutag.chat/F1").file
        let content = Attachment.content(.sealed(sealed), name: "photo.jpg", mimetype: "image/jpeg", size: 12,
                                         width: 640, height: 480)
        #expect(content["msgtype"]?.string == "m.image")
        #expect(content["url"] == nil)
        let read = try #require(Attachment.read(content))
        #expect(read.source == .sealed(sealed))
        #expect(read.name == "photo.jpg")
        #expect(read.width == 640 && read.height == 480 && read.size == 12)
        #expect(read.isImage)

        let plain = Attachment.content(.plain(MXC("mxc://nyutag.chat/D2")!), name: "отчёт.pdf",
                                       mimetype: "application/pdf", size: 900)
        #expect(plain["msgtype"]?.string == "m.file")
        #expect(Attachment.read(plain)?.source == .plain(MXC("mxc://nyutag.chat/D2")!))
        #expect(Attachment.read(plain)?.isImage == false)
    }

    @Test func attachmentFromForeignClient() throws {
        // Чужой клиент: без filename, с миниатюрой по открытому адресу; GIF показываем файлом.
        let content = try JSONValue(parsing: """
        {"msgtype":"m.image","body":"cat.gif","url":"mxc://s/G",
         "info":{"mimetype":"image/gif","thumbnail_url":"mxc://s/T","w":10,"h":20}}
        """)
        let read = try #require(Attachment.read(content))
        #expect(read.name == "cat.gif")
        #expect(read.thumbnail == .plain(MXC("mxc://s/T")!))
        #expect(!read.isImage)
        #expect(Attachment.read(try JSONValue(parsing: #"{"msgtype":"m.image","body":"x"}"#)) == nil)
        #expect(Attachment.read(try JSONValue(parsing: #"{"msgtype":"m.text","body":"x","url":"mxc://s/G"}"#)) == nil)
    }
}
