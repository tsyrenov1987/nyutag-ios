import SwiftUI

@main
struct NyutagApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Ядро туннеля поднимается один раз на процесс; клиенты берут путь у TunnelHub.
        Task { await TunnelHub.shared.begin() }
        #if DEBUG
        SelfCheck.runIfAsked()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, phase in
            // После сна iOS могла забрать порт ядра: проверяем до того, как клиенты начнут переподключаться.
            if phase == .active { Task { await TunnelHub.shared.appBecameActive() } }
        }
    }
}
