// Нютаг. Профиль (имя, аватар, произвольные поля MSC4133) и личные чаты (account data `m.direct`).

import Foundation

/// Профиль пользователя: `displayname`, `avatar_url` и произвольные поля (`chat.nyutag.*` и др.).
public struct Profile: Sendable, Equatable {
    public var displayName: String?
    public var avatarURL: String?
    /// Все поля ответа, включая displayname и avatar_url.
    public var fields: [String: JSONValue]

    public init(displayName: String? = nil, avatarURL: String? = nil, fields: [String: JSONValue] = [:]) {
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.fields = fields
    }

    init(json: JSONValue) {
        let fields = json.object ?? [:]
        self.init(displayName: fields["displayname"]?.string, avatarURL: fields["avatar_url"]?.string, fields: fields)
    }

    /// Строковое значение произвольного поля; пустая строка считается отсутствием.
    public func string(_ key: String) -> String? {
        guard let value = fields[key]?.string, !value.isEmpty else { return nil }
        return value
    }
}

/// Ключи произвольных полей профиля Нютага (имена на проводе общие с другими клиентами).
public enum NyutagProfileKey: String, CaseIterable, Sendable {
    case about = "chat.nyutag.about"
    case toonto = "chat.nyutag.toonto"
    case ug = "chat.nyutag.ug"
    /// Год по восточному календарю в виде `<стихия>-<животное>`.
    case eastYear = "chat.nyutag.east_year"
}

public extension Profile {
    /// Значение поля Нютага; пусто или не строка — `nil`.
    subscript(key: NyutagProfileKey) -> String? { string(key.rawValue) }
}

/// Какой API произвольных полей профиля предлагает сервер.
public enum ProfileFieldsAPI: Sendable, Equatable {
    /// `/_matrix/client/v3/profile/{userId}/{key}` (Matrix 1.16, `m.profile_fields`).
    case stable
    /// `/_matrix/client/unstable/uk.tcpip.msc4133/profile/{userId}/{key}`.
    case unstable
    /// Сервер явно отключил произвольные поля.
    case disabled

    public static let stableCapability = "m.profile_fields"
    public static let unstableCapability = "uk.tcpip.msc4133.profile_fields"
    static let unstableVersion = "unstable/uk.tcpip.msc4133"

    /// Выбор по ответу `/capabilities`. Если ни одна из возможностей не упомянута, берём стабильный путь: так
    /// работают форки Нютага на Tuwunel.
    public init(capabilities json: JSONValue) {
        let caps = json["capabilities"]
        let stable = caps?[Self.stableCapability]
        let unstable = caps?[Self.unstableCapability]
        if let stable, stable["enabled"]?.bool != false {
            self = .stable
        } else if let unstable, unstable["enabled"]?.bool != false {
            self = .unstable
        } else if stable != nil || unstable != nil {
            self = .disabled
        } else {
            self = .stable
        }
    }
}

public extension MatrixClient {
    // MARK: Профиль

    /// Весь профиль. Неизвестный пользователь (404) даёт пустой профиль, как в форках.
    func profile(userID: String) async throws(MatrixError) -> Profile {
        do {
            return Profile(json: try await request(.get, "profile/\(userID)"))
        } catch where error.status == 404 {
            return Profile()
        }
    }

    func setDisplayName(userID: String, _ name: String) async throws(MatrixError) {
        let _: EmptyResponse = try await request(.put, "profile/\(userID)/displayname", body: ["displayname": .string(name)])
    }

    func setAvatarURL(userID: String, _ url: String) async throws(MatrixError) {
        let _: EmptyResponse = try await request(.put, "profile/\(userID)/avatar_url", body: ["avatar_url": .string(url)])
    }

    // MARK: Произвольные поля (MSC4133)

    func profileFieldsAPI() async throws(MatrixError) -> ProfileFieldsAPI {
        let json: JSONValue = try await request(.get, "capabilities")
        return ProfileFieldsAPI(capabilities: json)
    }

    private func fieldRoute(_ api: ProfileFieldsAPI) throws(MatrixError) -> String {
        switch api {
        case .stable: return MatrixClient.apiVersion
        case .unstable: return ProfileFieldsAPI.unstableVersion
        case .disabled: throw MatrixError(.server(status: 400, errcode: "M_FORBIDDEN", message: "поля профиля отключены"))
        }
    }

    /// Записать одно поле: `PUT …/profile/{userId}/{key}` с телом `{key: value}`.
    func setProfileField(userID: String, key: String, value: JSONValue,
                         api: ProfileFieldsAPI = .stable) async throws(MatrixError) {
        let _: EmptyResponse = try await request(.put, "profile/\(userID)/\(key)", version: fieldRoute(api),
                                                 body: [key: value])
    }

    /// Удалить поле. Отсутствующее поле (404) — тот же результат, не ошибка.
    func deleteProfileField(userID: String, key: String, api: ProfileFieldsAPI = .stable) async throws(MatrixError) {
        do {
            let _: EmptyResponse = try await request(.delete, "profile/\(userID)/\(key)", version: fieldRoute(api))
        } catch where error.status == 404 {
            return
        }
    }

    /// Применить правки полей Нютага по одной: значение — записать, `nil` или пустая строка — удалить поле.
    /// Порядок по имени ключа, чтобы обрыв посреди серии вёл себя одинаково.
    func applyProfileEdits(userID: String, _ edits: [NyutagProfileKey: String?],
                           api: ProfileFieldsAPI) async throws(MatrixError) {
        for key in edits.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            if let value = edits[key] ?? nil, !value.isEmpty {
                try await setProfileField(userID: userID, key: key.rawValue, value: .string(value), api: api)
            } else {
                try await deleteProfileField(userID: userID, key: key.rawValue, api: api)
            }
        }
    }

    // MARK: Личные чаты (m.direct)

    /// `m.direct`: собеседник → комнаты. Нет записи (404) — пустой словарь.
    func directRooms(userID: String) async throws(MatrixError) -> [String: [String]] {
        let json: JSONValue
        do {
            json = try await accountData(userID: userID, type: EventType.direct)
        } catch where error.status == 404 {
            return [:]
        }
        var result: [String: [String]] = [:]
        for (user, rooms) in json.object ?? [:] {
            result[user] = (rooms.array ?? []).compactMap(\.string)
        }
        return result
    }

    /// Существующий личный чат с `other` (первый из `m.direct`), если есть.
    func directRoom(userID: String, with other: String) async throws(MatrixError) -> String? {
        try await directRooms(userID: userID)[other]?.first
    }

    /// Добавить комнату в `m.direct`: читаем текущее, меняем только запись `other`, остальное пишем как было.
    /// Не атомарно: запись с другого устройства между чтением и записью может потеряться, у Matrix для
    /// account data нет условной записи.
    func addDirectRoom(userID: String, with other: String, roomID: String) async throws(MatrixError) {
        var content: [String: JSONValue]
        do {
            content = try await accountData(userID: userID, type: EventType.direct).object ?? [:]
        } catch where error.status == 404 {
            content = [:]
        }
        var rooms = (content[other]?.array ?? []).compactMap(\.string)
        guard !rooms.contains(roomID) else { return }
        rooms.append(roomID)
        content[other] = .array(rooms.map(JSONValue.string))
        try await setAccountData(userID: userID, type: EventType.direct, content: .object(content))
    }

    /// Создать личный чат: `is_direct`, приглашение, `trusted_private_chat`, шифрование по `encrypted`;
    /// затем запись в `m.direct`.
    @discardableResult
    func createDirectRoom(userID: String, with other: String, encrypted: Bool = true) async throws(MatrixError) -> String {
        let roomID = try await createRoom(CreateRoom(invite: [other], isDirect: true,
                                                     preset: "trusted_private_chat", encrypted: encrypted))
        try await addDirectRoom(userID: userID, with: other, roomID: roomID)
        return roomID
    }
}
