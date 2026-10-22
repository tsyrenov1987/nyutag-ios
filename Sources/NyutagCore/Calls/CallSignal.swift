// Нютаг. Звонок в комнате: четыре своих события.
// `chat.nyutag.ring` — открытый звонок-будильник: по его типу шлюз шлёт VoIP-пуш (пушкин nyutag_voip), поэтому
// он не шифруется и ничего секретного не несёт. Остальные — `chat.nyutag.call.offer|answer|end`, в шифрованной
// комнате идут шифром: в offer и answer лежат открытые ключи X25519, из которых стороны выводят ключ кадров.
// Групповой звонок (только в шифрованной комнате): будильник с `group`, дальше каждый вошедший шлёт
// `chat.nyutag.call.join` со слотом релея, своим ключом кадров и меткой, ушедший — `chat.nyutag.call.leave`.
// Ключ кадров защищён шифром комнаты: его читают только участники комнаты.
// `chat.nyutag.call.ringing` — не событие комнаты, а сообщение устройству (to-device): «у меня звонит». Звонящий по нему
// переходит от «Звоним…» к гудкам. В ленту и пуши оно не попадает, старые версии его просто не знают.

import Foundation

public enum CallEventType {
    public static let ring = "chat.nyutag.ring"
    public static let offer = "chat.nyutag.call.offer"
    public static let answer = "chat.nyutag.call.answer"
    public static let end = "chat.nyutag.call.end"
    public static let join = "chat.nyutag.call.join"
    public static let leave = "chat.nyutag.call.leave"
    public static let ringing = "chat.nyutag.call.ringing"

    static let all: Set<String> = [ring, offer, answer, end, join, leave]
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
    case ring(callID: String, video: Bool, lifetime: Duration, group: Bool = false)
    case offer(callID: String, key: Data, video: Bool)
    case answer(callID: String, key: Data, deviceID: String)
    case end(callID: String, reason: CallEndReason)
    /// Вошёл в групповой звонок: кадры с меткой `tag` открываются ключом `key`.
    case join(callID: String, slot: String, key: Data, tag: UInt32, deviceID: String)
    case leave(callID: String, deviceID: String)
    /// Будильник звенит на устройстве `deviceID` того, кому звонят. Идёт сообщением устройству, комнату несёт в себе.
    case ringing(callID: String, roomID: String, deviceID: String)

    public var callID: String {
        switch self {
        case .ring(let id, _, _, _), .offer(let id, _, _), .answer(let id, _, _), .end(let id, _), .join(let id, _, _, _, _),
             .leave(let id, _), .ringing(let id, _, _): id
        }
    }

    public var eventType: String {
        switch self {
        case .ring: CallEventType.ring
        case .offer: CallEventType.offer
        case .answer: CallEventType.answer
        case .end: CallEventType.end
        case .join: CallEventType.join
        case .leave: CallEventType.leave
        case .ringing: CallEventType.ringing
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
        case .ring(let id, let video, let lifetime, let group):
            let ms = Int(lifetime.components.seconds * 1000)
            return ["call_id": .string(id), "video": .bool(video), "lifetime": .int(ms), "group": .bool(group),
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
        case .join(let id, let slot, let key, let tag, let device):
            return ["call_id": .string(id), "slot": .string(slot), "key": .string(key.base64EncodedString()),
                    "tag": .int(Int(tag)), "device_id": .string(device), "version": .int(Self.version)]
        case .leave(let id, let device):
            return ["call_id": .string(id), "device_id": .string(device), "version": .int(Self.version)]
        case .ringing(let id, let room, let device):
            return ["call_id": .string(id), "room_id": .string(room), "device_id": .string(device),
                    "version": .int(Self.version)]
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
                         lifetime: .milliseconds(min(max(ms, 5_000), 120_000)), group: content["group"]?.bool ?? false)
        case CallEventType.offer:
            guard let key = key() else { return nil }
            self = .offer(callID: id, key: key, video: content["video"]?.bool ?? false)
        case CallEventType.answer:
            guard let key = key(), let device = content["device_id"]?.string else { return nil }
            self = .answer(callID: id, key: key, deviceID: device)
        case CallEventType.end:
            self = .end(callID: id, reason: CallEndReason(rawValue: content["reason"]?.string ?? "") ?? .hangUp)
        case CallEventType.join:
            guard let key = key(), let slot = content["slot"]?.string, CallID.isValid(slot),
                  let tag = content["tag"]?.int, tag > 0, tag <= Int(UInt32.max),
                  let device = content["device_id"]?.string else { return nil }
            self = .join(callID: id, slot: slot, key: key, tag: UInt32(tag), deviceID: device)
        case CallEventType.leave:
            guard let device = content["device_id"]?.string else { return nil }
            self = .leave(callID: id, deviceID: device)
        case CallEventType.ringing:
            guard let room = content["room_id"]?.string, room.hasPrefix("!"),
                  let device = content["device_id"]?.string else { return nil }
            self = .ringing(callID: id, roomID: room, deviceID: device)
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

    /// Из сообщения устройству: только «у меня звонит», комната — из содержимого.
    public init?(toDevice event: Event) {
        guard event.type == CallEventType.ringing, let sender = event.sender,
              let signal = CallSignal(type: event.type, content: event.content),
              case .ringing(_, let roomID, _) = signal else { return nil }
        self.init(signal: signal, roomID: roomID, sender: sender)
    }

    /// Будильник ещё звонит: старые из первой синхронизации или пришедшие с опозданием не поднимают экран.
    public func isRinging(now: Date = Date()) -> Bool {
        guard case .ring(_, _, let lifetime, _) = signal, let timestamp else { return false }
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
