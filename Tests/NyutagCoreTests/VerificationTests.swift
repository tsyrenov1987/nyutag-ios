import Foundation
@testable import NyutagCore
import NyutagCrypto
import Testing

/// Проверка по эмодзи (SAS) между устройствами на поддельном сервере.
@Suite struct VerificationTests {
    static let alice = "@alice:nyutag.chat"
    static let bob = "@bob:nyutag.chat"

    typealias Device = OutboundTests.Device

    func device(_ server: FakeHomeserver, _ user: String, _ id: String) async throws -> Device {
        try await OutboundTests().device(server, user, id)
    }

    /// Доставлять to-device, пока очереди не опустеют. `tamper` может подменить событие по дороге.
    func pump(_ server: FakeHomeserver, _ devices: [Device], tamper: (Device, Event) -> Event = { $1 }) async {
        for _ in 0..<10 {
            var any = false
            for device in devices {
                let events = server.takeToDevice(user: device.session.userID, device: device.session.deviceID)
                guard !events.isEmpty else { continue }
                any = true
                _ = await device.machine.receiveToDevice(events.map { tamper(device, $0) })
            }
            if !any { return }
        }
    }

    func flow(_ device: Device, _ id: String) async throws -> VerificationFlow {
        try #require(await device.machine.verification(id))
    }

    /// Запрос → готовность → старт → обмен ключами. Возвращает id проверки.
    func reachComparing(_ server: FakeHomeserver, from: Device, to: Device,
                        tamper: (Device, Event) -> Event = { $1 }) async throws -> String {
        let id = try await from.machine.requestVerification(userID: to.session.userID)
        await pump(server, [from, to])
        #expect(try await flow(to, id).state == .requested)
        #expect(try await flow(to, id).incoming)
        try await to.machine.acceptVerification(id)
        await pump(server, [from, to])
        #expect(try await flow(from, id).state == .ready)
        #expect(try await flow(from, id).otherDeviceID == to.session.deviceID)
        try await from.machine.startSas(id)
        await pump(server, [from, to], tamper: tamper)
        return id
    }

    @Test func ownNewDeviceGetsSignedByEmoji() async throws {
        let server = FakeHomeserver()
        let old = try await device(server, Self.alice, "A1")
        try await old.machine.bootstrapCrossSigning(password: nil)
        let new = try await device(server, Self.alice, "A2")
        let spare = try await device(server, Self.alice, "A3")
        #expect(try await old.machine.devices(for: [Self.alice]).first { $0.deviceID == "A2" }?.crossSigned == false)

        // Новое устройство просит проверку у своих; ответило A1, A3 получает отмену.
        let id = try await reachComparing(server, from: new, to: old)
        await pump(server, [spare])
        #expect(try await flow(spare, id).state == .cancelled(code: "m.accepted", reason: "Проверку приняло другое устройство"))

        let atNew = try await flow(new, id), atOld = try await flow(old, id)
        #expect(atNew.state == .comparing && atOld.state == .comparing)
        #expect(atNew.emoji == atOld.emoji && atNew.emoji?.count == 7)
        #expect(atNew.decimals == atOld.decimals && atNew.decimals?.allSatisfy { (1000...9191).contains($0) } == true)

        try await old.machine.confirmSas(id)
        await pump(server, [new, old])
        #expect(try await flow(old, id).state == .confirmed)
        try await new.machine.confirmSas(id)
        await pump(server, [new, old])
        #expect(try await flow(new, id).state == .done)
        #expect(try await flow(old, id).state == .done)

        // A1 подписал A2 ключом самоподписи: теперь A2 подтверждено, A3 — нет.
        let seen = try await old.machine.devices(for: [Self.alice])
        let a2 = try #require(seen.first { $0.deviceID == "A2" })
        #expect(a2.crossSigned)
        #expect(await old.machine.isVerified(a2))
        #expect(seen.first { $0.deviceID == "A3" }?.crossSigned == false)

        // A2 сверило A1 и получило от него ключи кросс-подписи: теперь подтверждено и для самого себя.
        await pump(server, [new, old])
        #expect(await new.machine.hasCrossSigningKeys)
        #expect(try await new.machine.ownCrossSigningKey(.userSigning) != nil)
        let mineAtNew = try #require(try await new.machine.devices(for: [Self.alice]).first { $0.deviceID == "A2" })
        #expect(mineAtNew.crossSigned)
        #expect(await new.machine.crossSigningIdentity(userID: Self.alice)?.verified == true)
    }

    /// Секреты просит устройство, которое никто не проверял: ему ничего не уходит.
    @Test func secretsNotGivenToUnverifiedDevice() async throws {
        let server = FakeHomeserver()
        let old = try await device(server, Self.alice, "A1")
        try await old.machine.bootstrapCrossSigning(password: nil)
        let stranger = try await device(server, Self.alice, "A3")
        let a1 = try #require(try await stranger.machine.devices(for: [Self.alice]).first { $0.deviceID == "A1" })
        try await stranger.machine.requestSecrets(from: a1)
        await pump(server, [old])
        let toStranger = server.takeToDevice(user: Self.alice, device: "A3")
        #expect(!toStranger.contains { $0.type == EventType.encrypted })
        #expect(await !stranger.machine.hasCrossSigningKeys)
    }

    /// Ответ пришёл на настоящий запрос, но от своего устройства, которое мы не проверяли: ключи не берём.
    @Test func secretsFromUnverifiedDeviceIgnored() async throws {
        let server = FakeHomeserver()
        let old = try await device(server, Self.alice, "A1")
        try await old.machine.bootstrapCrossSigning(password: nil)
        let new = try await device(server, Self.alice, "A2")
        // A1 доверяет A2, A2 не доверяет A1.
        let a2 = try #require(try await old.machine.devices(for: [Self.alice]).first { $0.deviceID == "A2" })
        try await old.machine.trustLocally(a2)
        let a1 = try #require(try await new.machine.devices(for: [Self.alice]).first { $0.deviceID == "A1" })
        try await new.machine.requestSecrets(from: a1)
        await pump(server, [old])
        let answers = server.takeToDevice(user: Self.alice, device: "A2")
        #expect(answers.filter { $0.type == EventType.encrypted }.count == 3)
        _ = await new.machine.receiveToDevice(answers)
        #expect(await !new.machine.hasCrossSigningKeys)
    }

    /// Непрошеный секрет и ключи, которые уже не совпадают с сервером, не принимаются.
    @Test func unsolicitedOrStaleSecretsIgnored() async throws {
        let server = FakeHomeserver()
        let old = try await device(server, Self.alice, "A1")
        try await old.machine.bootstrapCrossSigning(password: nil)
        let new = try await device(server, Self.alice, "A2")
        let id = try await reachComparing(server, from: old, to: new)
        try await old.machine.confirmSas(id)
        try await new.machine.confirmSas(id)
        await pump(server, [new])
        // A1 получает MAC, но запросы секретов пока придерживаем.
        let toOld = server.takeToDevice(user: Self.alice, device: "A1")
        let requests = toOld.filter { $0.type == "m.secret.request" }
        #expect(requests.count == 4)
        _ = await old.machine.receiveToDevice(toOld.filter { $0.type != "m.secret.request" })
        #expect(try await flow(old, id).state == .done)

        // A1 шлёт настоящие ключи, но с чужими id запроса: A2 их не берёт.
        let a2 = try #require(try await old.machine.devices(for: [Self.alice]).first { $0.deviceID == "A2" })
        for kind in [CryptoMachine.CrossSigningKind.master, .selfSigning] {
            let key = try #require(try await old.machine.ownCrossSigningKey(kind))
            _ = try await old.machine.sendEncryptedToDevice(type: "m.secret.send", content: [
                "request_id": .string("nobody-asked-\(kind.rawValue)"),
                "secret": .string(Base64.encodeUnpadded(key.rawRepresentation)),
            ], to: [a2])
        }
        await pump(server, [new])
        #expect(await new.machine.receivedCrossSigning.isEmpty)
        #expect(await !new.machine.hasCrossSigningKeys)

        // A1 отвечает на запросы, но до A2 ответ доходит, когда личность на сервере уже сменилась.
        _ = await old.machine.receiveToDevice(requests)
        let rogue = try await device(server, Self.alice, "A9")
        try await rogue.machine.bootstrapCrossSigning(password: nil)
        let answers = server.takeToDevice(user: Self.alice, device: "A2")
        #expect(answers.filter { $0.type == EventType.encrypted }.count == 3)
        _ = await new.machine.receiveToDevice(answers)
        #expect(await !new.machine.hasCrossSigningKeys)
    }

    @Test func usersVerifyEachOther() async throws {
        let server = FakeHomeserver()
        let alice = try await device(server, Self.alice, "A1")
        let bob = try await device(server, Self.bob, "B1")
        try await alice.machine.bootstrapCrossSigning(password: nil)
        try await bob.machine.bootstrapCrossSigning(password: nil)
        #expect(await alice.machine.crossSigningIdentity(userID: Self.bob)?.verified != true)

        let id = try await reachComparing(server, from: alice, to: bob)
        // Bob подтверждает первым: MAC Алисы приходит к нему уже после подтверждения, его — к Алисе раньше.
        try await bob.machine.confirmSas(id)
        await pump(server, [alice, bob])
        try await alice.machine.confirmSas(id)
        await pump(server, [alice, bob])
        #expect(try await flow(alice, id).state == .done)
        #expect(try await flow(bob, id).state == .done)

        // Каждый подписал мастер-ключ другого: личность и устройства собеседника подтверждены.
        let bobDevice = try #require(try await alice.machine.devices(for: [Self.bob]).first)
        #expect(await alice.machine.crossSigningIdentity(userID: Self.bob)?.verified == true)
        #expect(await alice.machine.isVerified(bobDevice))
        let aliceDevice = try #require(try await bob.machine.devices(for: [Self.alice]).first)
        #expect(await bob.machine.isVerified(aliceDevice))
    }

    @Test func swappedStarterKeyGivesDifferentEmoji() async throws {
        let server = FakeHomeserver()
        let alice = try await device(server, Self.alice, "A1")
        let bob = try await device(server, Self.bob, "B1")
        try await alice.machine.bootstrapCrossSigning(password: nil)
        try await bob.machine.bootstrapCrossSigning(password: nil)
        // Сервер подменяет ключ Алисы своим по дороге к Бобу.
        let mitm = Sas().publicKeyBase64
        let id = try await reachComparing(server, from: alice, to: bob) { device, event in
            guard device.session.userID == Self.bob, event.type == "m.key.verification.key",
                  case .object(var fields) = event.content else { return event }
            fields["key"] = .string(mitm)
            return Event(type: event.type, sender: event.sender, content: .object(fields))
        }
        let atAlice = try await flow(alice, id), atBob = try await flow(bob, id)
        #expect(atBob.state == .comparing)
        #expect(atAlice.emoji != atBob.emoji)
        // Люди видят разные эмодзи и отменяют; подписей нет.
        await bob.machine.cancelVerification(id, code: "m.mismatched_sas", reason: "Эмодзи не совпали")
        await pump(server, [alice, bob])
        #expect(try await flow(alice, id).state == .cancelled(code: "m.mismatched_sas", reason: "Эмодзи не совпали"))
        #expect(await bob.machine.crossSigningIdentity(userID: Self.alice)?.verified != true)
        await #expect(throws: E2EEError.self) { try await alice.machine.confirmSas(id) }
    }

    @Test func swappedAccepterKeyBreaksCommitment() async throws {
        let server = FakeHomeserver()
        let alice = try await device(server, Self.alice, "A1")
        let bob = try await device(server, Self.bob, "B1")
        let mitm = Sas().publicKeyBase64
        let id = try await reachComparing(server, from: alice, to: bob) { device, event in
            guard device.session.userID == Self.alice, event.type == "m.key.verification.key",
                  case .object(var fields) = event.content else { return event }
            fields["key"] = .string(mitm)
            return Event(type: event.type, sender: event.sender, content: .object(fields))
        }
        #expect(try await flow(alice, id).state == .cancelled(code: "m.mismatched_commitment",
                                                              reason: "Ключ не совпал с обязательством"))
        #expect(try await flow(bob, id).state == .cancelled(code: "m.mismatched_commitment",
                                                            reason: "Ключ не совпал с обязательством"))
    }

    @Test func forgedMacIsRejected() async throws {
        let server = FakeHomeserver()
        let alice = try await device(server, Self.alice, "A1")
        let bob = try await device(server, Self.bob, "B1")
        try await alice.machine.bootstrapCrossSigning(password: nil)
        try await bob.machine.bootstrapCrossSigning(password: nil)
        let id = try await reachComparing(server, from: alice, to: bob)
        try await alice.machine.confirmSas(id)
        try await bob.machine.confirmSas(id)
        // MAC ключа устройства Боба подменён по дороге к Алисе (список ключей при этом верный).
        await pump(server, [alice, bob]) { device, event in
            guard device.session.userID == Self.alice, event.type == "m.key.verification.mac",
                  case .object(var fields) = event.content, var macs = fields["mac"]?.object else { return event }
            macs["ed25519:B1"] = .string(Base64.encodeUnpadded(Random.bytes(32)))
            fields["mac"] = .object(macs)
            return Event(type: event.type, sender: event.sender, content: .object(fields))
        }
        #expect(try await flow(alice, id).state == .cancelled(code: "m.key_mismatch", reason: "Ключи не совпали"))
        #expect(await alice.machine.crossSigningIdentity(userID: Self.bob)?.verified != true)
        _ = try await alice.machine.devices(for: [Self.bob])
        #expect(await alice.machine.crossSigningIdentity(userID: Self.bob)?.verified != true)
    }

    @Test func bothStartAtOnceSmallerUserWins() async throws {
        let server = FakeHomeserver()
        let alice = try await device(server, Self.alice, "A1")
        let bob = try await device(server, Self.bob, "B1")
        let id = try await alice.machine.requestVerification(userID: Self.bob)
        await pump(server, [alice, bob])
        try await bob.machine.acceptVerification(id)
        await pump(server, [alice, bob])
        try await alice.machine.startSas(id)
        try await bob.machine.startSas(id)
        await pump(server, [alice, bob])
        let atAlice = try await flow(alice, id), atBob = try await flow(bob, id)
        #expect(atAlice.state == .comparing && atBob.state == .comparing)
        #expect(atAlice.emoji == atBob.emoji)
        // По спецификации остаётся start Алисы: её user_id меньше. Иначе с чужими клиентами проверка зависнет.
        #expect(await alice.machine.verifications[id]?.weStarted == true)
        #expect(await bob.machine.verifications[id]?.weStarted == false)
    }

    @Test func droppedKeyBreaksKeyList() async throws {
        let server = FakeHomeserver()
        let alice = try await device(server, Self.alice, "A1")
        let bob = try await device(server, Self.bob, "B1")
        try await alice.machine.bootstrapCrossSigning(password: nil)
        try await bob.machine.bootstrapCrossSigning(password: nil)
        let id = try await reachComparing(server, from: alice, to: bob)
        try await alice.machine.confirmSas(id)
        try await bob.machine.confirmSas(id)
        // Из MAC Боба выкинут мастер-ключ: подпись списка ключей больше не сходится.
        await pump(server, [alice, bob]) { device, event in
            guard device.session.userID == Self.alice, event.type == "m.key.verification.mac",
                  case .object(var fields) = event.content, var macs = fields["mac"]?.object else { return event }
            macs = macs.filter { $0.key == "ed25519:B1" }
            fields["mac"] = .object(macs)
            return Event(type: event.type, sender: event.sender, content: .object(fields))
        }
        #expect(try await flow(alice, id).state == .cancelled(code: "m.key_mismatch", reason: "Список ключей не совпал"))
    }

    @Test func staleRequestIgnored() async throws {
        let server = FakeHomeserver()
        let alice = try await device(server, Self.alice, "A1")
        let request = Event(type: "m.key.verification.request", sender: Self.bob, content: [
            "from_device": "B1", "methods": ["m.sas.v1"], "transaction_id": "old",
            "timestamp": .int(Int(Date().timeIntervalSince1970 * 1000) - 11 * 60 * 1000),
        ])
        _ = await alice.machine.receiveToDevice([request])
        #expect(await alice.machine.verification("old") == nil)
    }

    // MARK: В комнате

    static let room = "!dm:nyutag.chat"

    /// Доставить to-device и новые события комнаты всем устройствам, пока есть что доставлять.
    func pumpRoom(_ server: FakeHomeserver, _ devices: [Device], seen: inout Int) async {
        for _ in 0..<10 {
            await pump(server, devices)
            let events = server.events(roomID: Self.room)
            guard events.count > seen else { return }
            let fresh = Array(events[seen...])
            seen = events.count
            for device in devices { await device.machine.receiveRoomVerifications(fresh, roomID: Self.room) }
        }
    }

    /// Element проверяет собеседника в личном чате: все шаги идут зашифрованными событиями комнаты.
    @Test func userVerifiedInRoom() async throws {
        let server = FakeHomeserver()
        let alice = try await device(server, Self.alice, "A1")
        let bob = try await device(server, Self.bob, "B1")
        try await alice.machine.bootstrapCrossSigning(password: nil)
        try await bob.machine.bootstrapCrossSigning(password: nil)
        server.setMembers([Self.alice, Self.bob], roomID: Self.room)
        var seen = 0

        let id = try await alice.machine.requestVerification(userID: Self.bob, inRoom: Self.room)
        await pumpRoom(server, [alice, bob], seen: &seen)
        let incoming = try await flow(bob, id)
        #expect(incoming.state == .requested && incoming.incoming && incoming.roomID == Self.room)
        #expect(incoming.otherDeviceID == "A1")
        try await bob.machine.acceptVerification(id)
        await pumpRoom(server, [alice, bob], seen: &seen)
        #expect(try await flow(alice, id).otherDeviceID == "B1")
        try await alice.machine.startSas(id)
        await pumpRoom(server, [alice, bob], seen: &seen)
        let atAlice = try await flow(alice, id), atBob = try await flow(bob, id)
        #expect(atAlice.state == .comparing && atBob.state == .comparing)
        #expect(atAlice.emoji == atBob.emoji && atAlice.emoji?.count == 7)

        try await alice.machine.confirmSas(id)
        try await bob.machine.confirmSas(id)
        await pumpRoom(server, [alice, bob], seen: &seen)
        #expect(try await flow(alice, id).state == .done)
        #expect(try await flow(bob, id).state == .done)
        #expect(await alice.machine.crossSigningIdentity(userID: Self.bob)?.verified == true)
        #expect(await bob.machine.crossSigningIdentity(userID: Self.alice)?.verified == true)

        // Ничего не ушло через to-device и ничего не лежит в комнате открытым текстом.
        let events = server.events(roomID: Self.room)
        #expect(events.count >= 9)
        #expect(events.allSatisfy { $0.type == EventType.encrypted })
        #expect(events.first?.eventID == id)
    }

    /// Чужие запросы, старые события и ссылки из другой комнаты проверку не трогают.
    @Test func roomEventsForOthersIgnored() async throws {
        let server = FakeHomeserver()
        let alice = try await device(server, Self.alice, "A1")
        let now = Int(Date().timeIntervalSince1970 * 1000)
        func request(_ id: String, to: String, ts: Int) -> Event {
            Event(eventID: id, type: EventType.message, sender: Self.bob, originServerTS: ts, content: [
                "msgtype": "m.key.verification.request", "to": .string(to), "from_device": "B1",
                "methods": ["m.sas.v1"], "body": "",
            ])
        }
        await alice.machine.receiveRoomVerifications([
            request("$toCarol", to: "@carol:nyutag.chat", ts: now),
            request("$old", to: Self.alice, ts: now - 11 * 60 * 1000),
            request("$ok", to: Self.alice, ts: now),
        ], roomID: Self.room)
        #expect(await alice.machine.verification("$toCarol") == nil)
        #expect(await alice.machine.verification("$old") == nil)
        #expect(try await flow(alice, "$ok").state == .requested)

        // Отмена с правильной ссылкой, но из другой комнаты, не действует.
        let cancel = Event(eventID: "$c", type: "m.key.verification.cancel", sender: Self.bob, originServerTS: now,
                           content: ["code": "m.user", "reason": "", "m.relates_to": ["rel_type": "m.reference",
                                                                                      "event_id": "$ok"]])
        await alice.machine.receiveRoomVerifications([cancel], roomID: "!other:nyutag.chat")
        #expect(try await flow(alice, "$ok").state == .requested)
        await alice.machine.receiveRoomVerifications([cancel], roomID: Self.room)
        #expect(try await flow(alice, "$ok").state == .cancelled(code: "m.user", reason: ""))
    }

    /// На запрос в комнате ответило другое устройство того же человека: у этого запрос закрывается.
    @Test func otherOwnDeviceTookRoomRequest() async throws {
        let server = FakeHomeserver()
        let alice = try await device(server, Self.alice, "A1")
        let bob1 = try await device(server, Self.bob, "B1")
        let bob2 = try await device(server, Self.bob, "B2")
        server.setMembers([Self.alice, Self.bob], roomID: Self.room)
        var seen = 0
        let id = try await alice.machine.requestVerification(userID: Self.bob, inRoom: Self.room)
        await pumpRoom(server, [alice, bob1, bob2], seen: &seen)
        #expect(try await flow(bob2, id).state == .requested)
        try await bob1.machine.acceptVerification(id)
        await pumpRoom(server, [alice, bob1, bob2], seen: &seen)
        #expect(try await flow(alice, id).otherDeviceID == "B1")
        #expect(try await flow(bob1, id).state == .ready)
        #expect(try await flow(bob2, id).state == .cancelled(code: "m.accepted", reason: "Проверку приняло другое устройство"))
    }
}
