// Живой релей звонков: тот же путь, что у приложения (дверь → nginx ядра с проверкой токена → релей на rtc).
// Нужен стенд `tools/test-env.sh` с дверью (NYUTAG_TEST_DOOR, NYUTAG_TEST_DOOR_KEY); SSH не нужен.

import Foundation
@testable import NyutagCore
import Testing

@Suite(.enabled(if: LiveEnv.available && LiveEnv.doorAvailable, "нет стенда или двери"))
struct LiveCallRelayTests {
    @Test func twoLinksMeetInSlot() async throws {
        let login = MatrixClient(homeserver: LiveEnv.homeserver!)
        let session = try await login.login(user: LiveEnv.user!, password: LiveEnv.password!,
                                            deviceDisplayName: "Нютаг тест релея (Мак)")
        defer { Task { try? await login.logout() } }
        let core = LiveEnv.doorClient(accessToken: session.accessToken)

        // Без токена nginx не пускает к релею.
        let stranger = LiveEnv.doorClient(accessToken: "nope")
        let slot = CallID.make()
        let refused = try #require(await RelayLink.open(client: stranger, slot: slot))
        #expect(await next(refused.inbound) == nil)

        let a = try #require(await RelayLink.open(client: core, slot: slot))
        let b = try #require(await RelayLink.open(client: core, slot: slot))
        var inA = a.inbound.makeAsyncIterator(), inB = b.inbound.makeAsyncIterator()
        _ = await inA.next()
        // Оба в слоте: релей сообщает каждому.
        var sawTwo = false
        for _ in 0..<3 where !sawTwo { if case .peers(2) = await inB.next() { sawTwo = true } }
        #expect(sawTwo)
        let packet = Data((0..<101).map { UInt8($0) })
        let clock = ContinuousClock(), started = clock.now
        b.send(packet)
        var got: Data?
        for _ in 0..<4 where got == nil { if case .packet(let data) = await inA.next() { got = data } }
        print("relay: кадр туда-обратно через ядро и rtc за \(clock.now - started)")
        #expect(got == packet)
        a.close()
        b.close()
    }

    private func next(_ stream: AsyncStream<RelayInbound>) async -> RelayInbound? {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
    }
}
