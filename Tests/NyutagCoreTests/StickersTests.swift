// Нютаг. Стикеры: наборы MSC2545 читаются и правятся, событие m.sticker ходит туда и обратно, лента показывает его
// как вложение-стикер.

import Foundation
import Testing
@testable import NyutagCore

@Suite struct StickersTests {
    let me = "@me:nyutag.test"

    @Test("набор читается: эмодзи-картинки не считаются стикерами, имя набора из pack")
    func readPack() {
        let content: JSONValue = [
            "pack": ["display_name": "Соёмбо", "usage": ["sticker"]],
            "images": [
                "hello": ["url": "mxc://nyutag.test/a", "body": "Сайн байна", "info": ["mimetype": "image/png", "w": 512, "h": 512]],
                "smile": ["url": "mxc://nyutag.test/b", "usage": ["emoticon"]],
                "broken": ["url": "not-an-mxc"],
            ],
        ]
        let pack = StickerPack.read(content, fallbackName: "Мои")
        #expect(pack.name == "Соёмбо")
        #expect(pack.stickers.map(\.shortcode) == ["hello"])
        #expect(pack.stickers.first?.body == "Сайн байна")
        #expect(pack.stickers.first?.width == 512)
        #expect(StickerPack.read(nil, fallbackName: "Мои") == StickerPack(name: "Мои", stickers: []))
    }

    @Test("добавить и убрать: имя не повторяется, набор помечен стикерным")
    func addRemove() throws {
        let a = Sticker(shortcode: "кот", mxc: try #require(MXC("mxc://nyutag.test/1")), mimetype: "image/png", width: 300, height: 200)
        var content = StickerPack.adding(a, to: nil, packName: "Мои")
        #expect(content["pack"]?["display_name"]?.string == "Мои")
        #expect(content["images"]?["кот"]?["usage"] == ["sticker"])
        #expect(StickerPack.freeShortcode("кот", in: content) == "кот-2")
        let b = Sticker(shortcode: "кот-2", mxc: try #require(MXC("mxc://nyutag.test/2")))
        content = StickerPack.adding(b, to: content, packName: "Другое")
        #expect(content["pack"]?["display_name"]?.string == "Мои")
        #expect(StickerPack.read(content, fallbackName: "").stickers.map(\.shortcode) == ["кот", "кот-2"])
        content = StickerPack.removing("кот", from: content)
        #expect(StickerPack.read(content, fallbackName: "").stickers.map(\.shortcode) == ["кот-2"])
    }

    @Test("событие m.sticker: содержимое туда и обратно, лента показывает стикер как вложение без ключа")
    func stickerEvent() async throws {
        let mxc = try #require(MXC("mxc://nyutag.test/s"))
        let sticker = Sticker(shortcode: "hello", mxc: mxc, body: "Сайн байна", mimetype: "image/png", width: 512, height: 512)
        let content = sticker.content
        #expect(content["url"]?.string == "mxc://nyutag.test/s")
        #expect(content["body"]?.string == "Сайн байна")
        #expect(content["info"]?["w"]?.int == 512)
        #expect(Sticker.read(content)?.mxc == mxc)
        #expect(Sticker.read(["body": "x"]) == nil)

        let store = try Store.inMemory()
        try await store.upsert(RoomRecord(id: "!r", membership: .join))
        try await store.append([
            Event(eventID: "$s", type: EventType.sticker, sender: me, originServerTS: 100, content: content, roomID: "!r"),
        ])
        let items = try await ChatFeed.items(roomID: "!r", store: store, me: me)
        let item = try #require(items.first)
        #expect(item.body == .attachment(.sticker, caption: nil))
        let attachment = try #require(item.attachment)
        #expect(attachment.isSticker)
        #expect(attachment.source == .plain(mxc))
        #expect(attachment.name == "Сайн байна")
        #expect(attachment.width == 512)
    }

    @Test("свой набор: на сервер и в базу, наборы комнаты из её состояния")
    func ownPackAndRoomPacks() async throws {
        let server = FakeHomeserver()
        let session = server.session(user: me, device: "D1")
        let client = server.client(for: session)
        let store = try Store.inMemory()
        let mxc = try #require(MXC("mxc://nyutag.test/1"))
        let first = try await client.addSticker(Sticker(shortcode: "кот", mxc: mxc), userID: me, packName: "Мои", store: store)
        let second = try await client.addSticker(Sticker(shortcode: "кот", mxc: mxc), userID: me, packName: "Мои", store: store)
        #expect(first.shortcode == "кот")
        #expect(second.shortcode == "кот-2")
        let onServer = StickerPack.read(server.accountDataContent(user: me, type: StickerPack.userType), fallbackName: "")
        #expect(onServer.stickers.map(\.shortcode) == ["кот", "кот-2"])
        #expect(try await Stickers.mine(store: store, packName: "Мои").stickers.count == 2)
        try await client.removeSticker("кот", userID: me, store: store)
        #expect(try await Stickers.mine(store: store, packName: "Мои").stickers.map(\.shortcode) == ["кот-2"])

        try await store.upsert(RoomRecord(id: "!r", membership: .join))
        try await store.setState(Event(eventID: "$p", type: StickerPack.roomType, sender: me, stateKey: "buryad",
                                       content: ["pack": ["display_name": "Буряад"], "images": ["a": ["url": "mxc://nyutag.test/a"]]],
                                       roomID: "!r"))
        try await store.setState(Event(eventID: "$e", type: StickerPack.roomType, sender: me, stateKey: "empty",
                                       content: ["images": [:]], roomID: "!r"))
        let packs = try await Stickers.inRoom("!r", store: store)
        #expect(packs.map(\.name) == ["Буряад"])
        #expect(packs.first?.stickers.map(\.shortcode) == ["a"])
    }
}
