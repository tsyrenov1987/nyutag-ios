// Нютаг. Защита от людей: блокировка собеседника, жалоба на сообщение, удаление аккаунта.
// Блокировка — стандартный `m.ignored_user_list` в данных учётки: сервер перестаёт присылать события
// блокированного, а мы на всякий случай прячем его реплики и у себя. Жалоба — `/rooms/{id}/report/{event}`,
// её читает администратор сервера. Удаление аккаунта — `/account/deactivate` с подтверждением паролем
// (обязательно для приложений с регистрацией: App Store 5.1.1(v)).

import Foundation

public enum IgnoredUsers {
    /// `{"ignored_users": {"@a:b": {}, …}}` → набор Matrix ID.
    public static func users(json: JSONValue?) -> Set<String> {
        guard let list = json?["ignored_users"]?.object else { return [] }
        return Set(list.keys.filter { $0.hasPrefix("@") })
    }

    public static func json(users: Set<String>) -> JSONValue {
        var list: [String: JSONValue] = [:]
        for user in users.sorted() { list[user] = [:] }
        return ["ignored_users": .object(list)]
    }

    public static func load(store: Store) async throws -> Set<String> {
        users(json: try await store.accountData(EventType.ignoredUsers))
    }
}

public extension MatrixClient {
    /// Новый список блокированных: на сервер и сразу в базу, чтобы лента спряталась до следующего /sync.
    func setIgnoredUsers(_ users: Set<String>, userID: String, store: Store) async throws {
        let content = IgnoredUsers.json(users: users)
        try await setAccountData(userID: userID, type: EventType.ignoredUsers, content: content)
        try await store.setAccountData(EventType.ignoredUsers, content: content)
    }

    /// Жалоба администратору сервера на сообщение. `score` по спецификации от -100 (худшее) до 0.
    func report(roomID: String, eventID: String, reason: String, score: Int = -100) async throws(MatrixError) {
        let _: EmptyResponse = try await request(.post, "rooms/\(roomID)/report/\(eventID)",
                                                 body: ["reason": .string(reason), "score": .int(score)])
    }

    /// Удалить аккаунт на сервере навсегда. Сервер просит подтвердить паролем (UIA): первый запрос без
    /// `auth` возвращает сессию подтверждения, второй идёт с паролем. `erase` просит стереть и содержимое
    /// (имя, аватар, реплики для новых участников), как того ждут от удаления аккаунта.
    func deactivate(userID: String, password: String) async throws(MatrixError) {
        let body: JSONValue = ["erase": .bool(true)]
        do {
            let _: EmptyResponse = try await request(.post, "account/deactivate", body: body)
        } catch {
            guard let session = error.uiaSession else { throw error }
            let auth: JSONValue = [
                "type": "m.login.password", "identifier": ["type": "m.id.user", "user": .string(userID)],
                "password": .string(password), "session": .string(session),
            ]
            let _: EmptyResponse = try await request(.post, "account/deactivate",
                                                     body: ["erase": .bool(true), "auth": auth])
        }
        setAccessToken(nil)
    }
}
