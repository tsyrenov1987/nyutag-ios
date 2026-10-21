// Нютаг. Наблюдение за сетью: сигнал, когда сменилась сеть (Wi-Fi ↔ сотовая, другой Wi-Fi по шлюзам),
// только пока связь есть. Адреса шлюзов наружу не выходят: нужен лишь признак «сеть другая».

import Foundation
import Network

enum NetworkWatch {
    static func changes() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let monitor = NWPathMonitor()
            // Монитор вызывает обработчик на одной своей очереди, поэтому «последний» ключ можно держать локально.
            nonisolated(unsafe) var last: String?
            monitor.pathUpdateHandler = { path in
                guard path.status == .satisfied else { return }
                let key = kind(of: path) + "|" + path.gateways.compactMap(address(of:)).sorted().joined(separator: ",")
                guard key != last else { return }
                last = key
                continuation.yield()
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "chat.nyutag.network-watch"))
        }
    }

    private static func kind(of path: NWPath) -> String {
        if path.usesInterfaceType(.wifi) { return "wifi" }
        if path.usesInterfaceType(.cellular) { return "cell" }
        if path.usesInterfaceType(.wiredEthernet) { return "wired" }
        return "other"
    }

    private static func address(of endpoint: NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let a): return "\(a)"
        case .ipv6(let a): return "\(a)"
        case .name(let name, _): return name
        @unknown default: return nil
        }
    }
}
