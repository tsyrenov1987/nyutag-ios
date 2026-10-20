// Нютаг. Пуши iPhone: регистрация устройства у шлюза на ядре и разбор того, что шлюз положил в пуш.
// Шлюз (Sygnal с нашим пушкином) живёт на loopback ядра, поэтому адрес пушера — 127.0.0.1: его открывает сервер,
// а не телефон. Флаг `nyutag_cipher` просит шлюз вложить шифротекст `m.room.encrypted` (если влезает в 4 КБ APNs):
// расширение уведомлений расшифрует его ключами из общей базы, не выходя в сеть — туннеля в расширении нет.

import Foundation

public enum ApplePusher {
    public enum Environment: String, Sendable {
        case production = "prod"
        case sandbox = "dev"
    }

    static let gateway = "http://127.0.0.1:5000/_matrix/push/v1/notify"
    static let appIDBase = "chat.nyutag.messenger.ios."
    static let cipherFlag = "nyutag_cipher"
    static let carriedKey = "nyutag_event"

    public static func appID(_ environment: Environment) -> String { appIDBase + environment.rawValue }

    /// Токен APNs в том виде, в каком его ждёт шлюз: шестнадцатеричная строка.
    public static func pushKey(_ token: Data) -> String { token.map { String(format: "%02x", $0) }.joined() }

    /// Зашифрованное событие, вложенное шлюзом в пуш; `nil`, если шлюз его не положил (не влезло, старый шлюз).
    public static func carriedEvent(in userInfo: [AnyHashable: Any]) -> Event? {
        guard let roomID = userInfo["room_id"] as? String, let eventID = userInfo["event_id"] as? String,
              let carried = userInfo[carriedKey], JSONSerialization.isValidJSONObject(carried),
              let data = try? JSONSerialization.data(withJSONObject: carried),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              let sender = json["sender"]?.string, let content = json["content"], content["ciphertext"] != nil else {
            return nil
        }
        return Event(eventID: eventID, type: EventType.encrypted, sender: sender, content: content, roomID: roomID)
    }
}

extension MatrixClient {
    /// Включить пуши на этом устройстве. Повторный вызов с тем же токеном обновляет запись, а не плодит новую.
    public func registerApplePush(token: Data, environment: ApplePusher.Environment, deviceName: String,
                                  language: String) async throws(MatrixError) {
        let body: JSONValue = [
            "kind": "http",
            "app_id": .string(ApplePusher.appID(environment)),
            "pushkey": .string(ApplePusher.pushKey(token)),
            "app_display_name": "Нютаг",
            "device_display_name": .string(deviceName),
            "lang": .string(language),
            "append": false,
            "data": [
                "url": .string(ApplePusher.gateway),
                // Без mutable-content iOS не запустит расширение и покажет пуш как есть.
                "default_payload": ["aps": ["mutable-content": 1]],
                ApplePusher.cipherFlag: 1,
            ],
        ]
        let _: EmptyResponse = try await request(.post, "pushers/set", body: body)
    }

    /// Выключить пуши этого устройства (выход, запрет уведомлений).
    public func removeApplePush(token: Data, environment: ApplePusher.Environment) async throws(MatrixError) {
        let body: JSONValue = [
            "kind": .null,
            "app_id": .string(ApplePusher.appID(environment)),
            "pushkey": .string(ApplePusher.pushKey(token)),
        ]
        let _: EmptyResponse = try await request(.post, "pushers/set", body: body)
    }
}
