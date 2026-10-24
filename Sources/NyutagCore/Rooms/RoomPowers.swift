// Нютаг. Права в группе и сообществе по `m.room.power_levels`: кто владелец, админ, модератор, что кому можно
// и как выглядит новое содержимое уровней после назначения или «пишут только админы». Создатель комнаты
// 12-й версии (и `additional_creators`) выше всех, хотя в `users` его нет.

import Foundation

public struct RoomPowers: Sendable, Equatable {
    public enum Role: Int, Sendable, Comparable {
        case member, moderator, admin, owner
        public static func < (a: Role, b: Role) -> Bool { a.rawValue < b.rawValue }
    }

    public static let admin = 100
    public static let moderator = 50

    /// Содержимое `m.room.power_levels`; пустое, если события нет.
    public let content: JSONValue
    public let creators: Set<String>

    public init(powerLevels: JSONValue?, creators: Set<String> = []) {
        content = powerLevels ?? .object([:])
        self.creators = creators
    }

    private func number(_ key: String, _ fallback: Int) -> Int { content[key]?.int ?? fallback }

    public func level(of userID: String) -> Int {
        if creators.contains(userID) { return Int.max }
        return content["users"]?[userID]?.int ?? number("users_default", 0)
    }

    public func role(of userID: String) -> Role {
        let level = level(of: userID)
        if level == Int.max { return .owner }
        if level >= Self.admin { return .admin }
        if level >= Self.moderator { return .moderator }
        return .member
    }

    /// Уровень, нужный для события; `state` — событие состояния (по умолчанию `state_default`, иначе `events_default`).
    public func needed(event type: String, state: Bool) -> Int {
        content["events"]?[type]?.int ?? (state ? number("state_default", 50) : number("events_default", 0))
    }

    public func canSend(_ userID: String, event type: String = EventType.message) -> Bool {
        level(of: userID) >= needed(event: type, state: false)
    }

    public func canSetState(_ userID: String, type: String) -> Bool {
        level(of: userID) >= needed(event: type, state: true)
    }

    public func canInvite(_ userID: String) -> Bool { level(of: userID) >= number("invite", 0) }

    /// Удалить чужую реплику.
    public func canRedactOthers(_ userID: String) -> Bool { level(of: userID) >= number("redact", 50) }

    /// Выгнать можно только того, кто ниже тебя.
    public func canKick(_ userID: String, _ target: String) -> Bool {
        userID != target && level(of: userID) >= number("kick", 50) && level(of: userID) > level(of: target)
    }

    public func canBan(_ userID: String, _ target: String) -> Bool {
        userID != target && level(of: userID) >= number("ban", 50) && level(of: userID) > level(of: target)
    }

    /// Поставить `target` уровень `to`: сам должен быть выше цели (или менять себя вниз) и не выдавать больше своего.
    public func canSetLevel(_ userID: String, _ target: String, to: Int) -> Bool {
        guard !creators.contains(target), canSetState(userID, type: EventType.powerLevels) else { return false }
        let mine = level(of: userID)
        guard to <= mine else { return false }
        return userID == target || mine > level(of: target)
    }

    /// Пишут только те, у кого уровень не ниже модератора.
    public var onlyAdminsWrite: Bool { needed(event: EventType.message, state: false) >= Self.moderator }

    /// Содержимое уровней с новым уровнем человека; уровень по умолчанию убирает его из `users`.
    public func setting(_ userID: String, to level: Int) -> JSONValue {
        var object = content.object ?? [:]
        var users = object["users"]?.object ?? [:]
        if level == number("users_default", 0) { users[userID] = nil } else { users[userID] = .int(level) }
        object["users"] = .object(users)
        return .object(object)
    }

    /// «Пишут только админы»: обычный уровень реплик поднимается до модератора, реакции остаются всем.
    public func writing(onlyAdmins: Bool) -> JSONValue {
        var object = content.object ?? [:]
        var events = object["events"]?.object ?? [:]
        if onlyAdmins {
            object["events_default"] = .int(Self.moderator)
            events[EventType.reaction] = .int(0)
        } else {
            object["events_default"] = .int(0)
            events[EventType.reaction] = nil
        }
        object["events"] = .object(events)
        return .object(object)
    }
}

public extension RoomPowers {
    /// Уровни и создатели из своей базы (состояние комнаты приходит с синхронизацией).
    static func local(roomID: String, store: Store) async throws -> RoomPowers {
        let levels = try await store.state(roomID, type: EventType.powerLevels, stateKey: "")
        var creators: Set<String> = []
        if let create = try await store.state(roomID, type: EventType.create).first {
            let version = create.content["room_version"]?.string ?? "1"
            if Int(version).map({ $0 >= 12 }) ?? true {
                creators = Set([create.sender].compactMap(\.self) + (create.content["additional_creators"]?.array ?? []).compactMap(\.string))
            }
        }
        return RoomPowers(powerLevels: levels, creators: creators)
    }
}

/// Ссылка на сообщество: `https://nyutag.chat/c/#<id>` (страница с кнопкой) и `nyutag://community/<id>` (из неё в приложение).
public enum CommunityLink {
    public static func web(_ roomID: String) -> URL {
        URL(string: "https://nyutag.chat/c/#" + (roomID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? roomID))!
    }

    public static func roomID(from url: URL) -> String? {
        let raw: String?
        if url.scheme == "nyutag", url.host == "community" {
            raw = url.path.split(separator: "/").first.map(String.init)
        } else if url.scheme == "https", url.host == "nyutag.chat", url.path.hasPrefix("/c") {
            raw = url.fragment
        } else {
            raw = nil
        }
        // У комнат 12-й версии id без «:сервер».
        guard let id = raw?.removingPercentEncoding, id.hasPrefix("!"), id.count > 1, !id.contains("/") else { return nil }
        return id
    }
}

/// Закреплённые реплики комнаты (`m.room.pinned_events`).
public enum PinnedEvents {
    public static let type = "m.room.pinned_events"

    public static func ids(_ content: JSONValue?) -> [String] {
        (content?["pinned"]?.array ?? []).compactMap(\.string)
    }

    /// Новое закреплённое — первым; повтор не задваивается.
    public static func pinning(_ eventID: String, _ pinned: Bool, in content: JSONValue?) -> JSONValue {
        var ids = ids(content).filter { $0 != eventID }
        if pinned { ids.insert(eventID, at: 0) }
        return ["pinned": .array(ids.map { .string($0) })]
    }
}

/// Участники комнаты по событиям `m.room.member`: кто внутри, кто стучится (заявка), кто заблокирован.
public struct Roster: Sendable, Equatable {
    public var joined: [Person] = []
    public var invited: [Person] = []
    public var knocking: [Person] = []
    public var banned: [Person] = []

    public init(_ members: [Event]) {
        for event in members where event.type == EventType.member {
            guard let userID = event.stateKey, !userID.isEmpty else { continue }
            let name = event.content["displayname"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? ChatDigest.localpart(userID)
            let person = Person(userID: userID, name: name, avatarURL: event.content["avatar_url"]?.string)
            switch event.content["membership"]?.string {
            case "join": joined.append(person)
            case "invite": invited.append(person)
            case "knock": knocking.append(person)
            case "ban": banned.append(person)
            default: break
            }
        }
        let byName: (Person, Person) -> Bool = { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        joined.sort(by: byName)
        invited.sort(by: byName)
        knocking.sort(by: byName)
        banned.sort(by: byName)
    }
}
