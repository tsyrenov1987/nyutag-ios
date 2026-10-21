// Нютаг. Связь с релеем звонков: WebSocket к `/_nyutag/relay/v1?slot=…` через тот же путь, что и запросы к ядру
// (туннель, свой CA). Бинарные сообщения — кадры собеседника как есть, текстовые — служебные (`{"peers":N}`).

import Foundation

public enum RelayInbound: Sendable, Equatable {
    case packet(Data)
    /// Сколько участников сейчас в слоте, считая нас.
    case peers(Int)
}

public final class RelayLink: Sendable {
    public static let path = "/_nyutag/relay/v1"

    private let task: URLSessionWebSocketTask
    public let inbound: AsyncStream<RelayInbound>
    private let continuation: AsyncStream<RelayInbound>.Continuation

    public init(_ task: URLSessionWebSocketTask) {
        self.task = task
        (inbound, continuation) = AsyncStream.makeStream(of: RelayInbound.self, bufferingPolicy: .bufferingNewest(256))
        task.maximumMessageSize = 256 << 10
        task.resume()
        let task = task, continuation = continuation
        Task.detached {
            while true {
                guard let message = try? await task.receive() else { break }
                switch message {
                case .data(let data): continuation.yield(.packet(data))
                case .string(let text):
                    if let data = text.data(using: .utf8), let json = try? JSONDecoder().decode(JSONValue.self, from: data),
                       let peers = json["peers"]?.int {
                        continuation.yield(.peers(peers))
                    }
                @unknown default: break
                }
            }
            continuation.finish()
        }
        // Пустой эфир (микрофон выключен, оба молчат) не должен рвать связь по таймауту релея.
        Task.detached { [weak task] in
            while let task, task.state == .running || task.state == .suspended {
                try? await Task.sleep(for: .seconds(15))
                task.sendPing { _ in }
            }
        }
    }

    public static func open(client: MatrixClient, slot: String) async -> RelayLink? {
        guard let task = try? await client.webSocket(path, query: ["slot": slot]) else { return nil }
        return RelayLink(task)
    }

    /// Не ждёт доставки: кадр, не успевший уйти, всё равно устарел бы.
    public func send(_ packet: Data) {
        task.send(.data(packet)) { _ in }
    }

    public func close() {
        task.cancel(with: .normalClosure, reason: nil)
        continuation.finish()
    }
}
