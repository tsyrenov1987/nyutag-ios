import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        // TODO: подключить расшифровку из NyutagCore.
        contentHandler(request.content)
    }

    override func serviceExtensionTimeWillExpire() {}
}
