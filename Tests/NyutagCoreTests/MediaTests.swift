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
}
