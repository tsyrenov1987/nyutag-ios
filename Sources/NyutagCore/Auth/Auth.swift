// Нютаг. Вход и выход: `m.login.password`, `whoami`, `logout`.

import Foundation

public struct Session: Codable, Sendable, Equatable {
    public let userID: String
    public let deviceID: String
    public let accessToken: String
    public let homeserver: URL

    public init(userID: String, deviceID: String, accessToken: String, homeserver: URL) {
        self.userID = userID
        self.deviceID = deviceID
        self.accessToken = accessToken
        self.homeserver = homeserver
    }

    /// `@user:nyutag.chat` → `user`.
    public var localpart: String {
        let withoutSigil = userID.dropFirst()
        return String(withoutSigil.prefix { $0 != ":" })
    }

    public var serverName: String {
        String(userID.drop { $0 != ":" }.dropFirst())
    }
}

public struct LoginResponse: Decodable, Sendable {
    public let userID: String
    public let accessToken: String
    public let deviceID: String

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case accessToken = "access_token"
        case deviceID = "device_id"
    }
}

public struct WhoAmI: Decodable, Sendable {
    public let userID: String
    public let deviceID: String?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case deviceID = "device_id"
    }
}

public extension MatrixClient {
    /// Вход по паролю. `user` принимает и localpart, и полный `@user:server`.
    func login(user: String, password: String, deviceID: String? = nil,
               deviceDisplayName: String) async throws(MatrixError) -> Session {
        var body: JSONValue = [
            "type": "m.login.password",
            "identifier": ["type": "m.id.user", "user": .string(user)],
            "password": .string(password),
            "initial_device_display_name": .string(deviceDisplayName),
        ]
        if let deviceID, case .object(var object) = body {
            object["device_id"] = .string(deviceID)
            body = .object(object)
        }
        let response: LoginResponse = try await request(.post, "login", body: body, authenticated: false)
        setAccessToken(response.accessToken)
        return Session(userID: response.userID, deviceID: response.deviceID,
                       accessToken: response.accessToken, homeserver: homeserver)
    }

    func whoAmI() async throws(MatrixError) -> WhoAmI {
        try await request(.get, "account/whoami")
    }

    /// Выход: токен на сервере отзывается, локальный токен сбрасывается даже при сетевой ошибке.
    func logout() async throws(MatrixError) {
        defer { setAccessToken(nil) }
        let _: EmptyResponse = try await request(.post, "logout")
    }
}
