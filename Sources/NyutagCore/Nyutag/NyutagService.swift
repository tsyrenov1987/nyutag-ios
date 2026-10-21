// Нютаг. Сервис `/_nyutag/v1` на ядре: приглашения, регистрация, вход по телефону или почте, сброс пароля,
// поиск друзей по номерам, обращения разработчика, состав дверей к ядру.
// В бою он за тем же адресом, что и Tuwunel (nginx разводит пути); на тестовом стенде отдельный порт.

import Foundation

public struct SignUpConfiguration: Sendable, Equatable {
    public let requiresInvite: Bool
    public let requiresContact: Bool
    public let emailAvailable: Bool
    public let phoneAvailable: Bool
    public let requiresEmail: Bool
    public let requiresPhone: Bool
    public let phoneUnverified: Bool
}

public struct Verification: Sendable, Equatable {
    public let sid: String
    public let resendAfter: Duration
}

public struct InviteCode: Sendable, Equatable {
    public let code: String
    public let expiresAt: Date?

    public init(code: String, expiresAt: Date?) {
        self.code = code
        self.expiresAt = expiresAt
    }

    /// Страница приглашения на сайте; код после `#` браузер на сервер сайта не отправляет.
    public var link: String { "https://nyutag.chat/i/#\(code)" }

    /// Код из ссылки `https://nyutag.chat/i/#КОД` или `nyutag://invite/КОД`; чужая ссылка — nil.
    public static func code(fromLink url: URL) -> String? {
        let raw: String?
        switch (url.scheme?.lowercased(), url.host?.lowercased()) {
        case ("nyutag", "invite"): raw = url.path.split(separator: "/").first.map(String.init)
        case ("https", "nyutag.chat") where url.path.hasPrefix("/i"): raw = url.fragment
        default: raw = nil
        }
        guard let raw else { return nil }
        let clean = raw.uppercased()
        guard clean.wholeMatch(of: /[0-9A-Z]{4}-?[0-9A-Z]{4}/) != nil else { return nil }
        return clean
    }
}

public enum ContactMedium: String, Sendable {
    case email, msisdn
}

public struct NyutagService: Sendable {
    let client: MatrixClient

    /// `client` с токеном нужен для запросов от имени участника (приглашения, поиск по номерам, свой номер).
    public init(client: MatrixClient) {
        self.client = client
    }

    public init(baseURL: URL, accessToken: String? = nil) {
        client = MatrixClient(homeserver: baseURL, accessToken: accessToken)
    }

    private func call(_ method: MatrixClient.Method, _ name: String, body: JSONValue? = nil,
                      authenticated: Bool = false) async throws(MatrixError) -> JSONValue {
        try await client.raw(method, "/_nyutag/v1/\(name)", body: body, authenticated: authenticated)
    }

    private func required(_ json: JSONValue, _ key: String, _ name: String) throws(MatrixError) -> String {
        guard let value = json[key]?.string else { throw MatrixError(.decoding("\(name): нет \(key)")) }
        return value
    }

    // MARK: Без входа

    public func configuration() async throws(MatrixError) -> SignUpConfiguration {
        let json = try await call(.get, "config")
        return SignUpConfiguration(requiresInvite: json["require_invite"]?.bool ?? true,
                                   requiresContact: json["require_contact"]?.bool ?? false,
                                   emailAvailable: json["email"]?.bool ?? false,
                                   phoneAvailable: json["msisdn"]?.bool ?? false,
                                   requiresEmail: json["require_email"]?.bool ?? false,
                                   requiresPhone: json["require_phone"]?.bool ?? false,
                                   phoneUnverified: json["phone_unverified"]?.bool ?? false)
    }

    /// Обращения разработчика: сырой список, язык и кнопки разбирает интерфейс.
    public func announcements() async throws(MatrixError) -> [JSONValue] {
        try await call(.get, "announce")["announcements"]?.array ?? []
    }

    /// Состав дверей к ядру `{"version", "paths", "retired", "doors"}`.
    public func catalogue() async throws(MatrixError) -> JSONValue {
        try await call(.get, "catalogue")
    }

    /// Годен ли код приглашения; возвращает Matrix ID пригласившего, если сервер его сообщает.
    public func checkInvite(_ code: String) async throws(MatrixError) -> (valid: Bool, inviter: String?) {
        let json = try await call(.post, "invites/check", body: ["code": .string(code)])
        return (json["valid"]?.bool == true, json["inviter"]?.string)
    }

    public func startVerification(medium: ContactMedium, address: String,
                                  inviteCode: String) async throws(MatrixError) -> Verification {
        let json = try await call(.post, "verify/start", body: [
            "medium": .string(medium.rawValue), "address": .string(address), "code": .string(inviteCode),
        ])
        return Verification(sid: try required(json, "sid", "verify/start"),
                            resendAfter: .seconds(json["resend_after_s"]?.int ?? 60))
    }

    public func checkVerification(sid: String, token: String) async throws(MatrixError) -> Bool {
        try await call(.post, "verify/check", body: ["sid": .string(sid), "token": .string(token)])["verified"]?.bool == true
    }

    /// Номер годен и не занят; возвращает его в виде `+7…`.
    public func checkPhone(_ phone: String, inviteCode: String) async throws(MatrixError) -> String {
        let json = try await call(.post, "phone/check", body: ["phone": .string(phone), "code": .string(inviteCode)])
        return try required(json, "phone", "phone/check")
    }

    /// Регистрация по приглашению; возвращает Matrix ID, войти потом обычным паролем.
    public func register(code: String, username: String, password: String, sid: String? = nil,
                         phone: String? = nil) async throws(MatrixError) -> String {
        var body: [String: JSONValue] = ["code": .string(code), "username": .string(username), "password": .string(password)]
        if let sid { body["sid"] = .string(sid) }
        if let phone { body["phone"] = .string(phone) }
        return try required(try await call(.post, "register", body: .object(body)), "user_id", "register")
    }

    /// Вход по телефону или почте: Matrix ID аккаунта, если пароль верный.
    public func resolve(identifier: String, password: String) async throws(MatrixError) -> String {
        let json = try await call(.post, "resolve", body: ["identifier": .string(identifier), "password": .string(password)])
        return try required(json, "user_id", "resolve")
    }

    public func startPasswordReset(address: String) async throws(MatrixError) -> Verification {
        let json = try await call(.post, "password/start", body: ["address": .string(address)])
        return Verification(sid: try required(json, "sid", "password/start"),
                            resendAfter: .seconds(json["resend_after_s"]?.int ?? 60))
    }

    public func resetPassword(sid: String, token: String, password: String) async throws(MatrixError) -> String {
        let json = try await call(.post, "password/reset", body: [
            "sid": .string(sid), "token": .string(token), "password": .string(password),
        ])
        return try required(json, "user_id", "password/reset")
    }

    // MARK: От имени участника

    /// Одноразовый код приглашения (живёт 7 дней).
    public func createInvite() async throws(MatrixError) -> InviteCode {
        let json = try await call(.post, "invites", authenticated: true)
        return InviteCode(code: try required(json, "code", "invites"),
                          expiresAt: json["expires_at"]?.int.map { Date(timeIntervalSince1970: Double($0) / 1000) })
    }

    /// Свои выпущенные коды (последние 50, без отозванных); `usedBy` у использованных.
    public func invites() async throws(MatrixError) -> [(invite: InviteCode, usedBy: String?)] {
        (try await call(.get, "invites", authenticated: true)["invites"]?.array ?? []).compactMap { item in
            guard let code = item["code"]?.string else { return nil }
            let expires = item["expires_at"]?.int.map { Date(timeIntervalSince1970: Double($0) / 1000) }
            return (InviteCode(code: code, expiresAt: expires), item["used_by"]?.string)
        }
    }

    /// Отзыв неиспользованного кода.
    public func revokeInvite(_ code: String) async throws(MatrixError) {
        _ = try await call(.delete, "invites/\(code)", authenticated: true)
    }

    /// Номер (как передан) → Matrix ID. Ненайденных в ответе нет.
    public func lookup(phones: [String]) async throws(MatrixError) -> [String: String] {
        let json = try await call(.post, "lookup", body: ["phones": .array(phones.map(JSONValue.string))], authenticated: true)
        var result: [String: String] = [:]
        for match in json["matches"]?.array ?? [] {
            if let phone = match["phone"]?.string, let userID = match["user_id"]?.string, result[phone] == nil {
                result[phone] = userID
            }
        }
        return result
    }

    /// Есть ли номер участника среди переданных номеров (сервер отвечает да или нет и номера не хранит).
    public func isInContacts(userID: String, phones: [String]) async throws(MatrixError) -> Bool {
        try await call(.post, "contact-check", body: [
            "user_id": .string(userID), "phones": .array(phones.map(JSONValue.string)),
        ], authenticated: true)["in_contacts"]?.bool == true
    }

    public func hasPhone() async throws(MatrixError) -> Bool {
        try await call(.get, "me", authenticated: true)["phone"]?.bool == true
    }

    public func setPhone(_ phone: String) async throws(MatrixError) {
        _ = try await call(.post, "me/phone", body: ["phone": .string(phone)], authenticated: true)
    }
}
