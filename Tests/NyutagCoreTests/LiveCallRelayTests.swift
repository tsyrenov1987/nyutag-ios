// Живой релей звонков: тот же путь, что у приложения (SOCKS → nginx ядра с проверкой токена → релей на rtc).
// Нужны стенд `tools/test-env.sh` и SOCKS до ядра: `ssh -N -D 11080 nyutag-core` (на ядре core.nyutag.chat —
// это 127.0.0.1), затем NYUTAG_TEST_SOCKS=11080.

import Foundation
@testable import NyutagCore
import Testing

@Suite(.enabled(if: LiveEnv.available && ProcessInfo.processInfo.environment["NYUTAG_TEST_SOCKS"] != nil,
                "нет стенда или NYUTAG_TEST_SOCKS"))
struct LiveCallRelayTests {
    @Test func twoLinksMeetInSlot() async throws {
        let login = MatrixClient(homeserver: LiveEnv.homeserver!)
        let session = try await login.login(user: LiveEnv.user!, password: LiveEnv.password!,
                                            deviceDisplayName: "Нютаг тест релея (Мак)")
        defer { Task { try? await login.logout() } }
        let port = UInt16(ProcessInfo.processInfo.environment["NYUTAG_TEST_SOCKS"]!)!
        let route = Route.socks5(try #require(SocksProxy(port: port, user: "probe", password: "probe")))
        let core = MatrixClient(homeserver: URL(string: "https://core.nyutag.chat:6167")!,
                                accessToken: session.accessToken, delegate: CertificateTrust.nyutagCore(), route: route)

        // Без токена nginx не пускает к релею.
        let stranger = MatrixClient(homeserver: URL(string: "https://core.nyutag.chat:6167")!, accessToken: "nope",
                                    delegate: CertificateTrust.nyutagCore(), route: route)
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
