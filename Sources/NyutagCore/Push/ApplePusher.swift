// Нютаг. Пуши iPhone: регистрация устройства у шлюза на ядре и разбор того, что шлюз положил в пуш.
// Шлюз (Sygnal с нашим пушкином) живёт на loopback ядра, поэтому адрес пушера — 127.0.0.1: его открывает сервер,
// а не телефон. Флаг `nyutag_cipher` просит шлюз вложить шифротекст `m.room.encrypted` (если влезает в 4 КБ APNs):
// расширение уведомлений расшифрует его ключами из общей базы, не выходя в сеть — своей гонки дверей в расширении нет.

import Foundation

public enum ApplePusher {
    public enum Environment: String, Sendable {
        case production = "prod"
        case sandbox = "dev"
        /// Тестовая сборка «Нютаг β» (свой bundle `chat.nyutag.messenger.dev`, песочница APNs): у шлюза своё
        /// приложение с этим topic, иначе APNs отвергнет токен как чужой.
        case beta = "beta"
    }

    static let gateway = "http://127.0.0.1:5000/_matrix/push/v1/notify"
    static let appIDBase = "chat.nyutag.messenger.ios."
    static let cipherFlag = "nyutag_cipher"
    static let carriedKey = "nyutag_event"

    public static func appID(_ environment: Environment) -> String { appIDBase + environment.rawValue }

    /// Токен APNs в том виде, в каком его ждёт шлюз: base64 с дополнением. Sygnal сам переводит его в hex для APNs;
    /// hex он бы раскодировал как base64 и отправил мусор (APNs отвечает 400 BadDeviceToken).
    public static func pushKey(_ token: Data) -> String { token.base64EncodedString() }

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

    /// Подпись, которую собрал сам шлюз: ключ локализации и аргументы в `aps.alert`. Строк под эти ключи в
    /// приложении нет, iOS показала бы ключ как есть — поэтому расширение разбирает их, когда не смогло
    /// прочитать событие само. Порядок аргументов у каждого ключа свой (так их кладёт Sygnal).
    public static func gatewayPreview(in userInfo: [AnyHashable: Any]) -> PushPreview? {
        guard let alert = (userInfo["aps"] as? [AnyHashable: Any])?["alert"] as? [AnyHashable: Any],
              let key = alert["loc-key"] as? String, let roomID = userInfo["room_id"] as? String else { return nil }
        let args = (alert["loc-args"] as? [Any])?.map { $0 as? String } ?? []
        func arg(_ i: Int) -> String? { i < args.count ? args[i].flatMap { $0.isEmpty ? nil : $0 } : nil }
        let sender: String?, room: String?, kind: PushPreview.Kind
        switch key {
        case "MSG_FROM_USER_IN_ROOM_WITH_CONTENT": (sender, room, kind) = (arg(0), arg(1), arg(2).map { .text($0) } ?? .other)
        case "MSG_FROM_USER_WITH_CONTENT": (sender, room, kind) = (arg(0), nil, arg(1).map { .text($0) } ?? .other)
        case "IMAGE_FROM_USER_IN_ROOM": (sender, room, kind) = (arg(0), arg(2), .image)
        case "IMAGE_FROM_USER": (sender, room, kind) = (arg(0), nil, .image)
        case "ACTION_FROM_USER_IN_ROOM": (sender, room, kind) = (arg(1), arg(0), arg(2).map { .text($0) } ?? .other)
        case "ACTION_FROM_USER": (sender, room, kind) = (arg(0), nil, arg(1).map { .text($0) } ?? .other)
        // Без текста шлюз шлёт, когда сообщение зашифровано.
        case "MSG_FROM_USER_IN_ROOM": (sender, room, kind) = (arg(0), arg(1), .locked)
        case "MSG_FROM_USER": (sender, room, kind) = (arg(0), nil, .locked)
        case "VOICE_CALL_FROM_USER", "VIDEO_CALL_FROM_USER": (sender, room, kind) = (arg(0), nil, .call)
        case "USER_INVITE_TO_NAMED_ROOM": (sender, room, kind) = (arg(0), arg(1), .invite)
        case "USER_INVITE_TO_CHAT": (sender, room, kind) = (arg(0), nil, .invite)
        default: return nil
        }
        return PushPreview(roomID: roomID, eventID: userInfo["event_id"] as? String ?? "", sender: nil,
                           senderName: sender, roomName: room, isDirect: room == nil, kind: kind)
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

// MARK: Звонки: VoIP-пуш

extension ApplePusher {
    /// У шлюза для VoIP своё приложение рядом с обычным: topic `<bundle>.voip`, пушкин `nyutag_voip.VoipPushkin`
    /// пропускает только будильник `chat.nyutag.ring`.
    public static func voipAppID(_ environment: Environment) -> String { appID(environment) + ".voip" }

    static let ringRuleID = "nyutag.ring"

    /// Будильник из VoIP-пуша: шлюз кладёт открытое событие целиком (комната, отправитель, содержимое).
    /// Время берём из `sender_ts`: серверного времени в пуше нет.
    public static func ring(in payload: [AnyHashable: Any]) -> CallMessage? {
        guard (payload["nyutag_ring"] as? Int) == 1 || (payload["nyutag_ring"] as? Bool) == true,
              let roomID = payload["room_id"] as? String, let sender = payload["sender"] as? String,
              let raw = payload["content"], JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw),
              let content = try? JSONDecoder().decode(JSONValue.self, from: data),
              let signal = CallSignal(type: CallEventType.ring, content: content) else { return nil }
        return CallMessage(signal: signal, roomID: roomID, sender: sender, eventID: payload["event_id"] as? String,
                           timestamp: content["sender_ts"]?.int)
    }

    /// Имя звонящего для экрана CallKit: что положил шлюз, иначе Matrix ID.
    public static func ringCaller(in payload: [AnyHashable: Any]) -> String? {
        for key in ["sender_display_name", "room_name", "sender"] {
            if let name = payload[key] as? String, !name.isEmpty { return name }
        }
        return nil
    }
}

extension MatrixClient {
    /// Второй пушер устройства — для звонков. Ни шифротекста, ни mutable-content: пуш будит PushKit, а не расширение.
    public func registerVoipPush(token: Data, environment: ApplePusher.Environment, deviceName: String,
                                 language: String) async throws(MatrixError) {
        let body: JSONValue = [
            "kind": "http",
            "app_id": .string(ApplePusher.voipAppID(environment)),
            "pushkey": .string(ApplePusher.pushKey(token)),
            "app_display_name": "Нютаг",
            "device_display_name": .string(deviceName),
            "lang": .string(language),
            "append": false,
            "data": ["url": .string(ApplePusher.gateway)],
        ]
        let _: EmptyResponse = try await request(.post, "pushers/set", body: body)
    }

    public func removeVoipPush(token: Data, environment: ApplePusher.Environment) async throws(MatrixError) {
        let body: JSONValue = [
            "kind": .null,
            "app_id": .string(ApplePusher.voipAppID(environment)),
            "pushkey": .string(ApplePusher.pushKey(token)),
        ]
        let _: EmptyResponse = try await request(.post, "pushers/set", body: body)
    }

    /// Правило «будильник звонка — уведомлять»: без него сервер не отдаст `chat.nyutag.ring` шлюзу (стандартные
    /// правила личного чата смотрят только сообщения). Повторная запись ничего не ломает.
    public func ensureRingPushRule() async throws(MatrixError) {
        let body: JSONValue = [
            "conditions": [["kind": "event_match", "key": "type", "pattern": .string(CallEventType.ring)]],
            "actions": ["notify"],
        ]
        let _: EmptyResponse = try await request(.put, "pushrules/global/override/\(ApplePusher.ringRuleID)", body: body)
    }
}
