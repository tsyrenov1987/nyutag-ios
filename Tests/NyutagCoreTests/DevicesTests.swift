// Нютаг. Список входов в аккаунт: порядок, переименование, выход на другом устройстве с паролем.

import Foundation
import Testing
@testable import NyutagCore

@Suite struct DevicesTests {
    let me = "@test:nyutag.chat"

    @Test("своё устройство первым, дальше по последнему входу")
    func order() {
        let list = [AccountDevice(deviceID: "A", lastSeenTS: 100), AccountDevice(deviceID: "B", lastSeenTS: 300),
                    AccountDevice(deviceID: "ME", lastSeenTS: 50), AccountDevice(deviceID: "C")]
        #expect(AccountDevice.sorted(list, current: "ME").map(\.deviceID) == ["ME", "B", "A", "C"])
    }

    @Test("ответ сервера разбирается")
    func decode() throws {
        let json = #"{"device_id":"QWE","display_name":"Нютаг iPhone","last_seen_ts":1761000000000,"last_seen_ip":"10.0.0.1"}"#
        let device = try JSONDecoder().decode(AccountDevice.self, from: Data(json.utf8))
        #expect(device == AccountDevice(deviceID: "QWE", displayName: "Нютаг iPhone", lastSeenTS: 1_761_000_000_000, lastSeenIP: "10.0.0.1"))
        #expect(device.lastSeen == Date(timeIntervalSince1970: 1_761_000_000))
    }

    @Test("переименование и выход на другом устройстве только с паролем")
    func renameAndDelete() async throws {
        let server = FakeHomeserver()
        server.setPassword("секрет", user: me)
        let mine = server.session(user: me, device: "D1")
        let other = server.session(user: me, device: "D2")
        let client = server.client(for: mine)

        #expect(try await client.devices().map(\.deviceID) == ["D1", "D2"])
        try await client.renameDevice("D2", to: "Старый iPad")
        #expect(try await client.devices().first { $0.deviceID == "D2" }?.displayName == "Старый iPad")

        await #expect(throws: MatrixError.self) {
            try await client.deleteDevice("D2", userID: me, password: "не тот")
        }
        #expect(server.isTokenValid(other.accessToken))
        try await client.deleteDevice("D2", userID: me, password: "секрет")
        #expect(!server.isTokenValid(other.accessToken))
        #expect(server.isTokenValid(mine.accessToken))
        #expect(try await client.devices().map(\.deviceID) == ["D1"])
    }
}
