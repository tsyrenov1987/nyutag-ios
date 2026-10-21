// Нютаг. Звонок в комнате: четыре своих события.
// `chat.nyutag.ring` — открытый звонок-будильник: по его типу шлюз шлёт VoIP-пуш (пушкин nyutag_voip), поэтому
// он не шифруется и ничего секретного не несёт. Остальные — `chat.nyutag.call.offer|answer|end`, в шифрованной
// комнате идут шифром: в offer и answer лежат открытые ключи X25519, из которых стороны выводят ключ кадров.

import Foundation

public enum CallEventType {
    public static let ring = "chat.nyutag.ring"
    public static let offer = "chat.nyutag.call.offer"
    public static let answer = "chat.nyutag.call.answer"
    public static let end = "chat.nyutag.call.end"

    static let all: Set<String> = [ring, offer, answer, end]
}

public enum CallEndReason: String, Sendable, Equatable {
    case hangUp = "hangup"
    case declined
    case noAnswer = "no_answer"
    case busy
    case lost
    /// Принят на другом устройстве этого же человека.
    case elsewhere
}

public enum CallSignal: Sendable, Equatable {
    /// Звонок пошёл. `lifetime` — сколько звонить, после него будильник считается пропущенным.
    case ring(callID: String, video: Bool, lifetime: Duration)
    case offer(callID: String, key: Data, video: Bool)
    case answer(callID: String, key: Data, deviceID: String)
    case end(callID: String, reason: CallEndReason)

    public var callID: String {
        switch self {
        case .ring(let id, _, _), .offer(let id, _, _), .answer(let id, _, _), .end(let id, _): id
        }
    }

    public var eventType: String {
        switch self {
        case .ring: CallEventType.ring
        case .offer: CallEventType.offer
        case .answer: CallEventType.answer
        case .end: CallEventType.end
        }
    }

    /// Нужен ли шифр комнаты. Будильник открыт всегда: иначе сервер не узнает, что это звонок.
    public var wantsRoomEncryption: Bool {
        if case .ring = self { return false }
        return true
    }

    static let version = 1

    public var content: JSONValue {
        switch self {
        case .ring(let id, let video, let lifetime):
            let ms = Int(lifetime.components.seconds * 1000)
            return ["call_id": .string(id), "video": .bool(video), "lifetime": .int(ms),
                    "sender_ts": .int(Int(Date().timeIntervalSince1970 * 1000)),
                    // Пушкин передаёт телефону содержимое как есть; по этому полю приложение понимает, что звонок свой.
                    "m.call.intent": .string(video ? "video" : "audio"), "version": .int(Self.version)]
        case .offer(let id, let key, let video):
            return ["call_id": .string(id), "key": .string(key.base64EncodedString()), "video": .bool(video),
                    "version": .int(Self.version)]
        case .answer(let id, let key, let device):
            return ["call_id": .string(id), "key": .string(key.base64EncodedString()), "device_id": .string(device),
                    "version": .int(Self.version)]
        case .end(let id, let reason):
            return ["call_id": .string(id), "reason": .string(reason.rawValue), "version": .int(Self.version)]
        }
    }

    /// Разбор уже расшифрованного события. Чужие и битые — `nil`.
    public init?(type: String, content: JSONValue) {
        guard let id = content["call_id"]?.string, CallID.isValid(id) else { return nil }
        func key() -> Data? {
            guard let text = content["key"]?.string, let data = Data(base64Encoded: text), data.count == 32 else { return nil }
            return data
        }
        switch type {
        case CallEventType.ring:
            let ms = content["lifetime"]?.int ?? 45_000
            self = .ring(callID: id, video: content["video"]?.bool ?? false,
                         lifetime: .milliseconds(min(max(ms, 5_000), 120_000)))
        case CallEventType.offer:
            guard let key = key() else { return nil }
            self = .offer(callID: id, key: key, video: content["video"]?.bool ?? false)
        case CallEventType.answer:
            guard let key = key(), let device = content["device_id"]?.string else { return nil }
            self = .answer(callID: id, key: key, deviceID: device)
        case CallEventType.end:
            self = .end(callID: id, reason: CallEndReason(rawValue: content["reason"]?.string ?? "") ?? .hangUp)
        default:
            return nil
        }
    }
}

/// Сигнал вместе с тем, кто и когда его прислал.
public struct CallMessage: Sendable, Equatable {
    public let signal: CallSignal
    public let roomID: String
    public let sender: String
    public let eventID: String?
    /// Время сервера, мс с 1970.
    public let timestamp: Int?

    public init(signal: CallSignal, roomID: String, sender: String, eventID: String? = nil, timestamp: Int? = nil) {
        self.signal = signal
        self.roomID = roomID
        self.sender = sender
        self.eventID = eventID
        self.timestamp = timestamp
    }

    /// Из события ленты (шифрованное уже открыто). Событие без комнаты или отправителя не годится.
    public init?(_ event: Event, roomID: String) {
        guard CallEventType.all.contains(event.type), let sender = event.sender,
              let signal = CallSignal(type: event.type, content: event.content) else { return nil }
        self.init(signal: signal, roomID: roomID, sender: sender, eventID: event.eventID, timestamp: event.originServerTS)
    }

    /// Будильник ещё звонит: старые из первой синхронизации или пришедшие с опозданием не поднимают экран.
    public func isRinging(now: Date = Date()) -> Bool {
        guard case .ring(_, _, let lifetime) = signal, let timestamp else { return false }
        let age = now.timeIntervalSince1970 * 1000 - Double(timestamp)
        return age < Double(lifetime.components.seconds * 1000)
    }
}

public enum CallID {
    /// 16 случайных байт в hex.
    public static func make() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func isValid(_ id: String) -> Bool {
        (8...64).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}
