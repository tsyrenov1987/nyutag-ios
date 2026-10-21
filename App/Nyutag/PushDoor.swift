// Нютаг. Пуши в приложении: разрешение, токен APNs, пушер на сервере, касание по уведомлению.
// Текст уведомления собирает расширение (NyutagNSE); здесь только регистрация и то, что делать, когда пуш пришёл
// при открытом приложении или по нему коснулись.

import NyutagCore
import Observation
import UIKit
import UserNotifications

@MainActor @Observable
final class PushDoor {
    static let shared = PushDoor()

    /// Чат, по уведомлению которого коснулись: список чатов откроет его и сбросит.
    var tappedRoom: String?
    /// Открытый сейчас чат: его уведомления поверх него не показываем.
    @ObservationIgnored var openRoom: String?

    @ObservationIgnored private var token: Data?
    @ObservationIgnored private var waiting: [CheckedContinuation<Data?, Never>] = []

    /// β и магазинная сборка — разные bundle, у шлюза для них разные приложения.
    nonisolated static var environment: ApplePusher.Environment {
        if Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true { return .beta }
        #if DEBUG
        return .sandbox
        #else
        return .production
        #endif
    }

    /// Спросить разрешение и получить токен. Отказ или нет связи с APNs — `nil`.
    func requestToken() async -> Data? {
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) == true else { return nil }
        if let token { return token }
        UIApplication.shared.registerForRemoteNotifications()
        return await withCheckedContinuation { continuation in
            waiting.append(continuation)
            Task {
                // Нет ответа от APNs (сим-карта без сети, ограничения) — не держим вход.
                try? await Task.sleep(for: .seconds(20))
                self.answer(nil)
            }
        }
    }

    /// Токен, под которым пушер стоит на сервере сейчас: при выходе его снимаем.
    var currentToken: Data? { token }

    fileprivate func answer(_ token: Data?) {
        if let token { self.token = token }
        let waiting = waiting
        self.waiting = []
        for continuation in waiting { continuation.resume(returning: token) }
    }
}

/// Делегат приложения нужен ради двух вещей: токена APNs и уведомлений, пришедших при открытом приложении.
final class AppDoorman: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // Звонки: реестр PushKit заводим при каждом запуске, иначе VoIP-пуш не придёт.
        MainActor.assumeIsolated {
            let ringer = CallRinger.shared
            ringer.onToken = { token in Task { await AppSession.shared.enableVoip(token) } }
            ringer.onRing = { ring in
                Task {
                    await AppSession.shared.launch()
                    await AppSession.shared.calls.absorb(ring)
                }
            }
            ringer.start()
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        MainActor.assumeIsolated { PushDoor.shared.answer(deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        #if DEBUG
        print("ui-check: APNs отказал: \(error.localizedDescription)")
        #endif
        MainActor.assumeIsolated { PushDoor.shared.answer(nil) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        let room = notification.request.content.userInfo["room_id"] as? String
        let open = await MainActor.run { PushDoor.shared.openRoom }
        #if DEBUG
        let content = notification.request.content
        print("ui-check: пуш при открытом приложении: «\(content.title)» «\(content.body)», чат открыт: \(room != nil && room == open)")
        #endif
        if room != nil, room == open { return [] }
        return [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let room = response.notification.request.content.userInfo["room_id"] as? String else { return }
        await MainActor.run { PushDoor.shared.tappedRoom = room }
    }
}
