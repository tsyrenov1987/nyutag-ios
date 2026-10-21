// Нютаг. «Избранное» — чат с собой для заметок, ссылок и файлов. Одна комната на учётку, её номер лежит в данных
// учётки `chat.nyutag.saved_messages` `{"room_id": "!…"}` (формат общий с Android), поэтому с любого устройства
// открывается одна и та же. Комната обычная шифрованная, без приглашённых.

import Foundation

public enum SavedMessages {
    /// Имена, которые ставит сам Нютаг на своих языках: такое имя можно перевести на язык телефона.
    /// Имя, данное человеком, не трогаем.
    public static let defaultNames: Set<String> = ["Избранное", "Хадагалһан", "Saved messages"]

    public static func roomID(json: JSONValue?) -> String? {
        guard let id = json?["room_id"]?.string, id.hasPrefix("!") else { return nil }
        return id
    }

    public static func json(roomID: String) -> JSONValue { ["room_id": .string(roomID)] }

    /// Нужно ли переименовать на язык телефона.
    public static func needsRename(_ current: String, to localized: String) -> Bool {
        current != localized && defaultNames.contains(current)
    }

    public static func load(store: Store) async throws -> String? {
        roomID(json: try await store.accountData(EventType.savedMessages))
    }
}

public extension MatrixClient {
    /// Новая комната «Избранного»: создаём и сразу записываем в данные учётки.
    func createSavedMessages(name: String, topic: String, userID: String, store: Store) async throws -> String {
        let roomID = try await createRoom(.init(name: name, topic: topic))
        let content = SavedMessages.json(roomID: roomID)
        try await setAccountData(userID: userID, type: EventType.savedMessages, content: content)
        try await store.setAccountData(EventType.savedMessages, content: content)
        return roomID
    }
}
