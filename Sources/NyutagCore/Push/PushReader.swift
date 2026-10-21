// Нютаг. Текст пуша для расширения уведомлений (NSE). Пуш несёт room_id, event_id и, если влезло, шифротекст;
// событие берём из общего хранилища, из самого пуша или с сервера, расшифровываем ключами из того же хранилища.
// Расширение только читает: не синкается, не создаёт Olm-аккаунт и не рассылает ключи — это дело приложения.

import Foundation

/// Что показать в уведомлении. Подписи («Фото», «Звонок») выбирает приложение на языке пользователя.
public struct PushPreview: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case text(String)
        case image, video, audio, file, location, sticker, poll
        case call
        /// Служебный сигнал звонка (ring/offer/answer/end): уведомление не показывать, входящий будит VoIP-пуш.
        case signal
        /// Нас пригласили в комнату.
        case invite
        /// Зашифровано, а ключа сессии на устройстве ещё нет: показать нейтральное «Новое сообщение».
        case locked
        case other
    }

    public let roomID: String
    public let eventID: String
    public let sender: String?
    public let senderName: String?
    public let roomName: String?
    public let isDirect: Bool
    public let kind: Kind
}

public actor PushReader {
    let client: MatrixClient
    let store: Store
    let session: Session
    private var machine: CryptoMachine?

    public init(client: MatrixClient, store: Store, session: Session) {
        self.client = client
        self.store = store
        self.session = session
    }

    /// `carried` — событие, вложенное шлюзом в сам пуш (`ApplePusher.carriedEvent`): с ним сеть не нужна.
    public func preview(roomID: String, eventID: String, carried: Event? = nil) async throws(MatrixError) -> PushPreview {
        var event: Event
        if let local = try? await store.event(eventID) {
            event = local
        } else if let carried {
            event = carried
        } else {
            event = try await client.event(roomID: roomID, eventID: eventID)
        }
        var locked = false
        if event.type == EventType.encrypted {
            if let decrypted = await decrypt(event, roomID: roomID) { event = decrypted } else { locked = true }
        }
        let record = try? await store.room(roomID)
        var senderName: String?
        if let sender = event.sender {
            senderName = try? await store.state(roomID, type: EventType.member, stateKey: sender)?["displayname"]?.string
        }
        return PushPreview(roomID: roomID, eventID: eventID, sender: event.sender, senderName: senderName,
                           roomName: record?.name, isDirect: record?.isDirect ?? false,
                           kind: locked ? .locked : Self.kind(of: event, me: session.userID))
    }

    /// Расшифровка без побочных эффектов на аккаунт: машину открываем, только если приложение уже завело аккаунт.
    private func decrypt(_ event: Event, roomID: String) async -> Event? {
        if machine == nil {
            guard (try? await store.cryptoBlob("account")) != nil else { return nil }
            machine = try? await CryptoMachine(client: client, store: store, session: session)
        }
        return try? await machine?.decrypt(event, roomID: roomID).event
    }

    static func kind(of event: Event, me: String) -> PushPreview.Kind {
        switch event.type {
        case EventType.member:
            return event.stateKey == me && event.content["membership"]?.string == "invite" ? .invite : .other
        case EventType.sticker:
            return .sticker
        case "m.poll.start", "org.matrix.msc3381.poll.start":
            return .poll
        case "m.call.invite", EventType.call:
            return .call
        case CallEventType.ring, CallEventType.offer, CallEventType.answer, CallEventType.end:
            return .signal
        case EventType.message:
            break
        default:
            return .other
        }
        // Правка: показываем новый текст, а не «* старый».
        let content = event.content["m.new_content"] ?? event.content
        switch content["msgtype"]?.string {
        case "m.image": return .image
        case "m.video": return .video
        case "m.audio": return .audio
        case "m.file": return .file
        case "m.location": return .location
        default:
            guard let body = content["body"]?.string else { return .other }
            return .text(withoutReplyQuote(body))
        }
    }

    /// Старые клиенты кладут в ответ цитату `> <@кто> текст` и пустую строку перед самим ответом.
    static func withoutReplyQuote(_ body: String) -> String {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.hasPrefix("> ") == true else { return body }
        let rest = lines.drop(while: { $0.hasPrefix(">") }).drop(while: { $0.isEmpty })
        return rest.isEmpty ? body : rest.joined(separator: "\n")
    }
}
