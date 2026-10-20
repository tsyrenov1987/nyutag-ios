// Нютаг. Наблюдение за сетью: поток ключей вида `wifi:<отпечаток>` / `cell` / `wired`, только когда ключ меняется.
// Сам ключ считает NetworkKey из NyutagCore; здесь только чтение NWPath.

import Foundation
import Network
import NyutagCore

enum NetworkWatch {
    static func keys() -> AsyncStream<String> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let monitor = NWPathMonitor()
            // Монитор вызывает обработчик на одной своей очереди, поэтому «последний» ключ можно держать локально.
            nonisolated(unsafe) var last: String?
            monitor.pathUpdateHandler = { path in
                guard path.status == .satisfied else { return }
                let key = NetworkKey.make(kind: kind(of: path), gateways: path.gateways.compactMap(address(of:)))
                guard key != last else { return }
                last = key
                continuation.yield(key)
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "chat.nyutag.network-watch"))
        }
    }

    private static func kind(of path: NWPath) -> LinkKind {
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.cellular) { return .cellular }
        if path.usesInterfaceType(.wiredEthernet) { return .wired }
        return .other
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
