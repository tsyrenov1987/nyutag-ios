// Нютаг. Закреплённые чаты (до пяти) и папки. Лежат в данных учётки `chat.nyutag.chat_layout`, так же, как
// у Android-клиента: {"pins":["!room",…], "folders":[{"id","name","rooms":[…]}]}. Пустые поля не пишем,
// повторы и папки без имени при чтении отбрасываем: чужие или битые данные не должны ломать список.

import Foundation

public struct ChatFolder: Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var rooms: [String]

    public init(id: String, name: String, rooms: [String] = []) {
        self.id = id
        self.name = name
        self.rooms = rooms
    }
}

public struct ChatLayout: Sendable, Equatable {
    public static let maxPins = 5

    /// Сверху вниз: первый — самый верхний.
    public private(set) var pins: [String]
    public private(set) var folders: [ChatFolder]

    public init(pins: [String] = [], folders: [ChatFolder] = []) {
        var seen: Set<String> = []
        self.pins = Array(pins.filter { seen.insert($0).inserted }.prefix(Self.maxPins))
        var ids: Set<String> = []
        self.folders = folders.compactMap { folder in
            let id = folder.id.trimmingCharacters(in: .whitespaces)
            let name = folder.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !name.isEmpty, ids.insert(id).inserted else { return nil }
            var rooms: Set<String> = []
            return ChatFolder(id: id, name: name, rooms: folder.rooms.filter { rooms.insert($0).inserted })
        }
    }

    public init(json: JSONValue?) {
        let pins = json?["pins"]?.array?.compactMap(\.string) ?? []
        let folders = (json?["folders"]?.array ?? []).map { item in
            ChatFolder(id: item["id"]?.string ?? "", name: item["name"]?.string ?? "",
                       rooms: item["rooms"]?.array?.compactMap(\.string) ?? [])
        }
        self.init(pins: pins, folders: folders)
    }

    public var json: JSONValue {
        var object: [String: JSONValue] = [:]
        if !pins.isEmpty { object["pins"] = .array(pins.map(JSONValue.string)) }
        if !folders.isEmpty {
            object["folders"] = .array(folders.map { folder in
                var item: [String: JSONValue] = ["id": .string(folder.id), "name": .string(folder.name)]
                if !folder.rooms.isEmpty { item["rooms"] = .array(folder.rooms.map(JSONValue.string)) }
                return .object(item)
            })
        }
        return .object(object)
    }

    public func isPinned(_ roomID: String) -> Bool { pins.contains(roomID) }
    public var canPinMore: Bool { pins.count < Self.maxPins }

    /// Новый закреп встаёт наверх. Сверх пяти ничего не меняется.
    public func pinning(_ roomID: String, _ pinned: Bool) -> ChatLayout {
        var copy = self
        if !pinned {
            copy.pins.removeAll { $0 == roomID }
        } else if !isPinned(roomID), canPinMore {
            copy.pins.insert(roomID, at: 0)
        }
        return copy
    }

    public func addingFolder(id: String = UUID().uuidString.lowercased(), name: String, with roomID: String? = nil) -> ChatLayout {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !folders.contains(where: { $0.id == id }) else { return self }
        var copy = self
        copy.folders.append(ChatFolder(id: id, name: clean, rooms: roomID.map { [$0] } ?? []))
        return copy
    }

    public func renamingFolder(_ id: String, to name: String) -> ChatLayout {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return self }
        var copy = self
        for index in copy.folders.indices where copy.folders[index].id == id { copy.folders[index].name = clean }
        return copy
    }

    public func removingFolder(_ id: String) -> ChatLayout {
        var copy = self
        copy.folders.removeAll { $0.id == id }
        return copy
    }

    public func placing(_ roomID: String, in folderID: String, _ inside: Bool) -> ChatLayout {
        var copy = self
        for index in copy.folders.indices where copy.folders[index].id == folderID {
            if inside, !copy.folders[index].rooms.contains(roomID) {
                copy.folders[index].rooms.append(roomID)
            } else if !inside {
                copy.folders[index].rooms.removeAll { $0 == roomID }
            }
        }
        return copy
    }

    /// Список для показа: в папке — только её чаты; закреплённые сверху в своём порядке, остальные как были.
    public func arrange(_ lines: [ChatLine], folder folderID: String? = nil) -> [ChatLine] {
        var shown = lines
        if let folderID {
            let rooms = Set(folders.first { $0.id == folderID }?.rooms ?? [])
            shown = shown.filter { rooms.contains($0.id) }
        }
        let byID = Dictionary(shown.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let top = pins.compactMap { byID[$0] }
        let topIDs = Set(top.map(\.id))
        return top + shown.filter { !topIDs.contains($0.id) }
    }

    /// Что лежит в базе после последнего /sync (или нашей последней записи).
    public static func load(store: Store) async throws -> ChatLayout {
        ChatLayout(json: try await store.accountData(EventType.chatLayout))
    }
}

public extension MatrixClient {
    /// Пишем на сервер и сразу в базу: список меняется, не дожидаясь /sync.
    func save(_ layout: ChatLayout, userID: String, store: Store) async throws {
        try await setAccountData(userID: userID, type: EventType.chatLayout, content: layout.json)
        try await store.setAccountData(EventType.chatLayout, content: layout.json)
    }
}
