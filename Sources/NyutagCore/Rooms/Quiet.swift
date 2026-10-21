// Нютаг. Чат «без звука»: правило уведомлений комнаты (`pushrules/global/room/{roomID}`) с пустыми действиями —
// сервер перестаёт слать пуши по этой комнате, а само правило приходит всем устройствам в `m.push_rules`
// данных учётки. Снять — удалить правило. Локальную копию правил правим сразу, чтобы колокольчик в списке
// поменялся до следующего /sync.

import Foundation

public enum MutedRooms {
    /// Комнаты без звука из содержимого `m.push_rules`: правила комнаты (`global.room`), которые включены
    /// и не содержат действия `notify`.
    public static func rooms(json: JSONValue?) -> Set<String> {
        var muted: Set<String> = []
        for rule in json?["global"]?["room"]?.array ?? [] {
            guard let roomID = rule["rule_id"]?.string, rule["enabled"]?.bool != false else { continue }
            let actions = rule["actions"]?.array ?? []
            if !actions.contains(.string("notify")) { muted.insert(roomID) }
        }
        return muted
    }

    public static func load(store: Store) async throws -> Set<String> {
        rooms(json: try await store.accountData(EventType.pushRules))
    }

    /// Те же правила с добавленным (или снятым) правилом комнаты.
    public static func apply(json: JSONValue?, roomID: String, muted: Bool) -> JSONValue {
        var global = json?["global"]?.object ?? [:]
        var rules = (global["room"]?.array ?? []).filter { $0["rule_id"]?.string != roomID }
        if muted {
            rules.append(["rule_id": .string(roomID), "default": false, "enabled": true, "actions": []])
        }
        global["room"] = .array(rules)
        var content = json?.object ?? [:]
        content["global"] = .object(global)
        return .object(content)
    }
}

public extension MatrixClient {
    /// Комната без звука (или снова со звуком): правило на сервер и сразу в базу.
    func setRoomMuted(roomID: String, _ muted: Bool, store: Store) async throws {
        if muted {
            let _: EmptyResponse = try await request(.put, "pushrules/global/room/\(roomID)", body: ["actions": []])
        } else {
            do {
                let _: EmptyResponse = try await request(.delete, "pushrules/global/room/\(roomID)")
            } catch where error.errcode == "M_NOT_FOUND" {
                // Правила и так нет.
            }
        }
        let current = try await store.accountData(EventType.pushRules)
        try await store.setAccountData(EventType.pushRules, content: MutedRooms.apply(json: current, roomID: roomID, muted: muted))
    }
}

public extension People {
    /// Все, с кем есть общие чаты (кроме сообществ и себя): собеседники из `m.direct` плюс участники
    /// вошедших комнат. Из них зовут в новую группу. Имя из личного чата главнее.
    static func acquaintances(store: Store, me: String) async throws -> [Person] {
        var byID: [String: Person] = [:]
        for room in try await store.rooms(membership: .join) where !room.isSpace {
            for person in try await members(roomID: room.id, store: store, me: me) where byID[person.userID] == nil {
                byID[person.userID] = person
            }
        }
        for person in try await known(store: store, me: me) { byID[person.userID] = person }
        return byID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Участники комнаты (вошедшие и приглашённые), кроме себя: имя из записи участника, иначе ник.
    static func members(roomID: String, store: Store, me: String) async throws -> [Person] {
        try await store.state(roomID, type: EventType.member)
            .filter { $0.stateKey != me && ["join", "invite"].contains($0.content["membership"]?.string ?? "") }
            .map { member in
                let name = member.content["displayname"]?.string.flatMap { $0.isEmpty ? nil : $0 }
                return Person(userID: member.stateKey, name: name ?? ChatDigest.localpart(member.stateKey),
                              avatarURL: member.content["avatar_url"]?.string)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
