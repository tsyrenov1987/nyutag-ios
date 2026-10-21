// Нютаг. Где открыт аккаунт: список входов (`/devices`), переименование и выход на чужом устройстве.
// Удаление входа сервер подтверждает паролем (UIA), как и удаление аккаунта; вместе со входом пропадают
// его ключи шифрования, поэтому то устройство больше не получит новые сообщения.

import Foundation

public struct AccountDevice: Sendable, Equatable, Identifiable, Decodable {
    public let deviceID: String
    public let displayName: String?
    public let lastSeenTS: Int64?
    public let lastSeenIP: String?

    public var id: String { deviceID }
    public var lastSeen: Date? { lastSeenTS.map { Date(timeIntervalSince1970: Double($0) / 1000) } }

    public init(deviceID: String, displayName: String? = nil, lastSeenTS: Int64? = nil, lastSeenIP: String? = nil) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.lastSeenTS = lastSeenTS
        self.lastSeenIP = lastSeenIP
    }

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id", displayName = "display_name", lastSeenTS = "last_seen_ts", lastSeenIP = "last_seen_ip"
    }

    /// Своё устройство первым, остальные — от недавних к давним.
    public static func sorted(_ devices: [AccountDevice], current: String) -> [AccountDevice] {
        devices.sorted { a, b in
            if (a.deviceID == current) != (b.deviceID == current) { return a.deviceID == current }
            if a.lastSeenTS != b.lastSeenTS { return (a.lastSeenTS ?? 0) > (b.lastSeenTS ?? 0) }
            return a.deviceID < b.deviceID
        }
    }
}

public extension MatrixClient {
    private struct DevicesResponse: Decodable, Sendable { let devices: [AccountDevice] }

    func devices() async throws(MatrixError) -> [AccountDevice] {
        let response: DevicesResponse = try await request(.get, "devices")
        return response.devices
    }

    func renameDevice(_ deviceID: String, to name: String) async throws(MatrixError) {
        let _: EmptyResponse = try await request(.put, "devices/\(deviceID)", body: ["display_name": .string(name)])
    }

    /// Выйти на другом устройстве. Первый запрос без `auth` возвращает сессию подтверждения, второй — с паролем.
    func deleteDevice(_ deviceID: String, userID: String, password: String) async throws(MatrixError) {
        let path = "devices/\(deviceID)"
        do {
            let _: EmptyResponse = try await request(.delete, path, body: [:])
        } catch {
            guard let session = error.uiaSession else { throw error }
            let auth: JSONValue = [
                "type": "m.login.password", "identifier": ["type": "m.id.user", "user": .string(userID)],
                "password": .string(password), "session": .string(session),
            ]
            let _: EmptyResponse = try await request(.delete, path, body: ["auth": auth])
        }
    }
}
