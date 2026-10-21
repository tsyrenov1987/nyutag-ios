// Нютаг. Расширение уведомлений: текст пуша собираем на устройстве. Сессия и база общие с приложением (связка
// и контейнер группы). Туннеля в расширении нет: событие берём из общей базы или из шифротекста, который шлюз
// вложил в пуш; только если нет ни того ни другого — пробуем ядро напрямую с пином нашего CA.
// Не вышло — оставляем подпись шлюза или «Новое сообщение».

import Foundation
import NyutagCore
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    private let delivery = Delivery()

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        delivery.arm(base: request.content, handler: contentHandler)
        let userInfo = request.content.userInfo
        guard let roomID = userInfo["room_id"] as? String, let eventID = userInfo["event_id"] as? String else {
            return delivery.finish(nil)
        }
        let delivery = delivery
        let carried = ApplePusher.carriedEvent(in: userInfo)
        Task {
            delivery.finish(await Self.preview(roomID: roomID, eventID: eventID, carried: carried))
        }
    }

    override func serviceExtensionTimeWillExpire() {
        delivery.finish(nil)
    }

    private static func preview(roomID: String, eventID: String, carried: Event?) async -> PushPreview? {
        guard let shelf = SharedShelf(appGroup: SharedShelf.appGroup),
              let session = try? SessionVault.shared.load(),
              let store = try? shelf.openStore(for: session.userID) else { return nil }
        // Порт ядра снаружи закрыт: без пути не ждём связи и укладываемся в отведённые расширению секунды.
        let configuration = MatrixClient.defaultConfiguration()
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 8
        let client = MatrixClient(homeserver: session.homeserver, accessToken: session.accessToken,
                                  configuration: configuration, delegate: CertificateTrust.nyutagCore())
        return try? await PushReader(client: client, store: store, session: session)
            .preview(roomID: roomID, eventID: eventID, carried: carried)
    }
}

/// Ровно один вызов обработчика: успели прочитать событие — его текст, нет или истекло время — нейтральный.
private final class Delivery: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((UNNotificationContent) -> Void)?
    private var base: UNNotificationContent?

    func arm(base: UNNotificationContent, handler: @escaping (UNNotificationContent) -> Void) {
        lock.withLock {
            self.base = base
            self.handler = handler
        }
    }

    func finish(_ preview: PushPreview?) {
        let taken = lock.withLock { () -> (UNNotificationContent, (UNNotificationContent) -> Void)? in
            defer { handler = nil; base = nil }
            guard let handler, let base else { return nil }
            return (base, handler)
        }
        guard let (base, handler) = taken else { return }
        let shown = preview ?? ApplePusher.gatewayPreview(in: base.userInfo)
        // Сигнал звонка: отдаём уведомление без текста и звука — такое iOS не показывает.
        if shown?.kind == .signal { return handler(UNNotificationContent()) }
        handler(shown.map { PushWording.content(for: $0, base: base) } ?? PushWording.neutral(base))
    }
}

/// Слова уведомления. Пока по-русски; перевод на бурятский и английский — вместе с интерфейсом.
enum PushWording {
    static func neutral(_ base: UNNotificationContent) -> UNNotificationContent {
        let content = mutable(base)
        if content.body.isEmpty { content.body = "Новое сообщение" }
        if content.title.isEmpty { content.title = "Нютаг" }
        return content
    }

    static func content(for preview: PushPreview, base: UNNotificationContent) -> UNNotificationContent {
        let content = mutable(base)
        let who = preview.senderName ?? preview.sender ?? ""
        if preview.isDirect || preview.roomName == nil {
            content.title = who.isEmpty ? "Нютаг" : who
        } else {
            content.title = preview.roomName ?? "Нютаг"
            content.subtitle = who
        }
        content.body = body(preview.kind)
        content.threadIdentifier = preview.roomID
        return content
    }

    static func body(_ kind: PushPreview.Kind) -> String {
        switch kind {
        case .text(let text): text
        case .image: "Фото"
        case .video: "Видео"
        case .audio: "Голосовое сообщение"
        case .file: "Файл"
        case .location: "Место на карте"
        case .sticker: "Стикер"
        case .poll: "Опрос"
        case .call: "Звонок"
        case .invite: "Приглашает в чат"
        case .locked, .other, .signal: "Новое сообщение"
        }
    }

    private static func mutable(_ base: UNNotificationContent) -> UNMutableNotificationContent {
        (base.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
    }
}
