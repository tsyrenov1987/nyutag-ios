import SwiftUI

@main
struct NyutagApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(AppDoorman.self) private var doorman

    init() {
        // Гонка дверей стартует один раз на процесс и не ждёт главного потока (он занят первым экраном);
        // клиенты берут дверь у DoorHub.
        Task.detached { await DoorHub.shared.begin() }
        #if DEBUG
        SelfCheck.runIfAsked()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, phase in
            // За время сна дверь могли запереть: проверяем до того, как клиенты начнут переподключаться.
            if phase == .active { Task { await DoorHub.shared.appBecameActive() } }
        }
    }
}
