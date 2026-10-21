// Нютаг. Стикеры: наборы картинок по MSC2545 (как в Element и Android-клиенте). Свой набор лежит в данных учётки
// `im.ponies.user_emotes`, наборы комнаты — в её состоянии `im.ponies.room_emotes` (ключ состояния — имя набора).
// Стикер в ленте — событие `m.sticker` с `body`, `url` и `info`: открытая картинка, ключа у неё нет, и в
// зашифрованной комнате тоже (так во всех клиентах: стикер — не секрет, а картинка из общего набора).

import Foundation

public struct Sticker: Sendable, Equatable, Identifiable {
    /// Короткое имя в наборе: по нему же стикер ищут и удаляют.
    public let shortcode: String
    public let mxc: MXC
    /// Подпись: `body` в наборе, иначе короткое имя.
    public let body: String
    public let mimetype: String?
    public let width: Int?
    public let height: Int?

    public var id: String { shortcode }

    public init(shortcode: String, mxc: MXC, body: String? = nil, mimetype: String? = nil, width: Int? = nil, height: Int? = nil) {
        self.shortcode = shortcode
        self.mxc = mxc
        self.body = body ?? shortcode
        self.mimetype = mimetype
        self.width = width
        self.height = height
    }

    /// Содержимое события `m.sticker`.
    public var content: JSONValue {
        var info: [String: JSONValue] = [:]
        if let mimetype { info["mimetype"] = .string(mimetype) }
        if let width, let height {
            info["w"] = .int(width)
            info["h"] = .int(height)
        }
        return .object(["body": .string(body), "url": .string(mxc.description), "info": .object(info)])
    }

    /// Стикер из события `m.sticker`; у битого содержимого — `nil`.
    public static func read(_ content: JSONValue) -> Sticker? {
        guard let mxc = content["url"]?.string.flatMap(MXC.init) else { return nil }
        let info = content["info"]
        let body = content["body"]?.string ?? ""
        return Sticker(shortcode: body, mxc: mxc, body: body, mimetype: info?["mimetype"]?.string,
                       width: info?["w"]?.int, height: info?["h"]?.int)
    }
}

/// Набор стикеров: свой или комнаты.
public struct StickerPack: Sendable, Equatable {
    public static let userType = "im.ponies.user_emotes"
    public static let roomType = "im.ponies.room_emotes"

    public let name: String
    public let stickers: [Sticker]

    public init(name: String, stickers: [Sticker]) {
        self.name = name
        self.stickers = stickers
    }

    /// Набор из содержимого `im.ponies.*_emotes`. Картинки только для эмодзи (`usage: ["emoticon"]`) не берём:
    /// это не стикеры, а замена смайлам в тексте. Порядок — как записан (JSON без порядка: по имени).
    public static func read(_ content: JSONValue?, fallbackName: String) -> StickerPack {
        let packUsage = usage(content?["pack"])
        var stickers: [Sticker] = []
        for (shortcode, image) in content?["images"]?.object ?? [:] {
            guard let mxc = image["url"]?.string.flatMap(MXC.init) else { continue }
            let own = usage(image) ?? packUsage
            if let own, !own.contains("sticker") { continue }
            let info = image["info"]
            stickers.append(Sticker(shortcode: shortcode, mxc: mxc, body: image["body"]?.string, mimetype: info?["mimetype"]?.string,
                                    width: info?["w"]?.int, height: info?["h"]?.int))
        }
        let name = content?["pack"]?["display_name"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
        return StickerPack(name: name, stickers: stickers.sorted { $0.shortcode < $1.shortcode })
    }

    private static func usage(_ json: JSONValue?) -> Set<String>? {
        json?["usage"]?.array.map { Set($0.compactMap(\.string)) }
    }

    /// То же содержимое с добавленным стикером (замена по короткому имени). Набор помечаем как стикерный.
    public static func adding(_ sticker: Sticker, to content: JSONValue?, packName: String) -> JSONValue {
        var root = content?.object ?? [:]
        var images = root["images"]?.object ?? [:]
        var info: [String: JSONValue] = [:]
        if let mimetype = sticker.mimetype { info["mimetype"] = .string(mimetype) }
        if let w = sticker.width, let h = sticker.height {
            info["w"] = .int(w)
            info["h"] = .int(h)
        }
        images[sticker.shortcode] = .object(["url": .string(sticker.mxc.description), "body": .string(sticker.body),
                                             "info": .object(info), "usage": ["sticker"]])
        root["images"] = .object(images)
        var pack = root["pack"]?.object ?? [:]
        if pack["display_name"] == nil { pack["display_name"] = .string(packName) }
        root["pack"] = .object(pack)
        return .object(root)
    }

    /// То же содержимое без стикера.
    public static func removing(_ shortcode: String, from content: JSONValue?) -> JSONValue {
        var root = content?.object ?? [:]
        var images = root["images"]?.object ?? [:]
        images[shortcode] = nil
        root["images"] = .object(images)
        return .object(root)
    }

    /// Свободное короткое имя: `name`, иначе `name-2`, `name-3`…
    public static func freeShortcode(_ wanted: String, in content: JSONValue?) -> String {
        let taken = Set(content?["images"]?.object?.keys.map { $0 } ?? [])
        if !taken.contains(wanted) { return wanted }
        var n = 2
        while taken.contains("\(wanted)-\(n)") { n += 1 }
        return "\(wanted)-\(n)"
    }
}

public enum Stickers {
    /// Свой набор из базы.
    public static func mine(store: Store, packName: String) async throws -> StickerPack {
        StickerPack.read(try await store.accountData(StickerPack.userType), fallbackName: packName)
    }

    /// Наборы комнаты (из её состояния), без пустых.
    public static func inRoom(_ roomID: String, store: Store) async throws -> [StickerPack] {
        try await store.state(roomID, type: StickerPack.roomType)
            .map { StickerPack.read($0.content, fallbackName: $0.stateKey) }
            .filter { !$0.stickers.isEmpty }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

public extension MatrixClient {
    /// Добавить стикер в свой набор: на сервер и сразу в базу. Возвращает стикер с занятым именем.
    func addSticker(_ sticker: Sticker, userID: String, packName: String, store: Store) async throws -> Sticker {
        let current = try await store.accountData(StickerPack.userType)
        let named = Sticker(shortcode: StickerPack.freeShortcode(sticker.shortcode, in: current), mxc: sticker.mxc, body: sticker.body,
                            mimetype: sticker.mimetype, width: sticker.width, height: sticker.height)
        let content = StickerPack.adding(named, to: current, packName: packName)
        try await setAccountData(userID: userID, type: StickerPack.userType, content: content)
        try await store.setAccountData(StickerPack.userType, content: content)
        return named
    }

    func removeSticker(_ shortcode: String, userID: String, store: Store) async throws {
        let content = StickerPack.removing(shortcode, from: try await store.accountData(StickerPack.userType))
        try await setAccountData(userID: userID, type: StickerPack.userType, content: content)
        try await store.setAccountData(StickerPack.userType, content: content)
    }
}
