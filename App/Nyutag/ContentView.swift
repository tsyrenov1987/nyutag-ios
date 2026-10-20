import SwiftUI
import NyutagCore

/// Заглушка: показывает, что движок слинкован. Дизайн — задача следующей фазы.
struct ContentView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Нютаг")
                .font(.largeTitle.bold())
            Text("Движок: \(String(describing: NyutagService.self))")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
