// Нютаг. Обмен ключами комнат между своими устройствами: запрос недостающего ключа (`m.room_key_request`),
// ответ подтверждённому своему устройству (`m.forwarded_room_key`) и отказы в ключе (`m.room_key.withheld`).

import Foundation
import NyutagCrypto

extension CryptoMachine {
    public static let withheldType = "m.room_key.withheld"

    // MARK: Запрос

    /// Попросить ключ сессии у своих устройств. `false`, если такой запрос уже отправлен.
    @discardableResult
    public func requestRoomKey(roomID: String, sessionID: String, senderKey: String) async throws(E2EEError) -> Bool {
        let requestID = TransactionID.make()
        guard try await storing({
            try await store.addKeyRequest(sessionID: sessionID, senderKey: senderKey, roomID: roomID, requestID: requestID)
        }) else { return false }
        let content: JSONValue = [
            "action": "request", "requesting_device_id": .string(deviceID), "request_id": .string(requestID),
            "body": ["algorithm": .string(Self.megolmAlgorithm), "room_id": .string(roomID),
                     "sender_key": .string(senderKey), "session_id": .string(sessionID)],
        ]
        do {
            try await client.sendToDevice(type: EventType.roomKeyRequest, messages: [userID: ["*": content]])
        } catch {
            try? await store.removeKeyRequest(sessionID: sessionID, senderKey: senderKey)
            throw .server(error)
        }
        return true
    }

    /// Попросить ключ для события, которое не расшифровалось.
    @discardableResult
    public func requestRoomKey(for event: Event, roomID: String) async throws(E2EEError) -> Bool {
        guard let sessionID = event.content["session_id"]?.string else { throw .badPayload("нет session_id") }
        return try await requestRoomKey(roomID: roomID, sessionID: sessionID,
                                        senderKey: event.content["sender_key"]?.string ?? "")
    }

    /// Ключ получен: запрос больше не нужен ни этому, ни другим устройствам.
    func settleKeyRequest(sessionID: String, senderKey: String) async {
        var requestID = try? await store.keyRequestID(sessionID: sessionID, senderKey: senderKey)
        if requestID == nil { requestID = try? await store.keyRequestID(sessionID: sessionID, senderKey: "") }
        guard let requestID else { return }
        try? await store.removeKeyRequest(sessionID: sessionID, senderKey: senderKey)
        try? await store.removeKeyRequest(sessionID: sessionID, senderKey: "")
        let cancel: JSONValue = ["action": "request_cancellation", "requesting_device_id": .string(deviceID),
                                 "request_id": .string(requestID)]
        try? await client.sendToDevice(type: EventType.roomKeyRequest, messages: [userID: ["*": cancel]])
    }

    func hasKeyRequest(sessionID: String, senderKey: String) async -> Bool {
        if (try? await store.keyRequestID(sessionID: sessionID, senderKey: senderKey)) != nil { return true }
        return (try? await store.keyRequestID(sessionID: sessionID, senderKey: "")) != nil
    }

    // MARK: Ответ

    /// Своё устройство по id; если его нет в списке, список перезапрашивается (устройство могло только появиться).
    func ownDevice(_ id: String) async throws(E2EEError) -> DeviceInfo? {
        if let device = try await devices(for: [userID]).first(where: { $0.deviceID == id }) { return device }
        try await storing { try await store.markDeviceListsChanged([userID]) }
        return try await devices(for: [userID]).first { $0.deviceID == id }
    }

    /// Отдать ключ на запрос своего же подтверждённого устройства. Чужим и неподтверждённым ключи не отдаём.
    /// Возвращает, ушёл ли ключ.
    @discardableResult
    func answerRoomKeyRequest(_ event: Event) async throws(E2EEError) -> Bool {
        let content = event.content
        guard event.sender == userID, content["action"]?.string == "request",
              let requester = content["requesting_device_id"]?.string, requester != deviceID,
              let body = content["body"], body["algorithm"]?.string == Self.megolmAlgorithm,
              let roomID = body["room_id"]?.string, let sessionID = body["session_id"]?.string else { return false }
        guard let device = try await ownDevice(requester), await isVerified(device) else { return false }
        let stored: StoredMegolmSession?
        if let senderKey = body["sender_key"]?.string, !senderKey.isEmpty {
            stored = try await storing { try await store.megolmSession(senderKey: senderKey, sessionID: sessionID) }
        } else {
            stored = try await storing { try await store.megolmSession(sessionID: sessionID) }
        }
        guard let stored, stored.roomID == roomID else { return false }
        let exported: String
        do { exported = try stored.session.export() } catch { throw .crypto(error) }
        let forwarded: JSONValue = [
            "algorithm": .string(Self.megolmAlgorithm), "room_id": .string(roomID),
            "sender_key": .string(stored.senderKey), "session_id": .string(sessionID), "session_key": .string(exported),
            "sender_claimed_ed25519_key": .string(stored.claimedEd25519 ?? ""), "forwarding_curve25519_key_chain": [],
        ]
        return !(try await sendEncryptedToDevice(type: EventType.forwardedRoomKey, content: forwarded, to: [device])).isEmpty
    }

    /// Пересланный ключ принимаем, только если сами его просили и прислало своё подтверждённое устройство.
    func acceptForwardedRoomKey(_ event: Event) async throws(E2EEError) {
        let content = event.content
        guard event.sender == userID, let from = event.unsigned?["sender_key"]?.string,
              content["algorithm"]?.string == Self.megolmAlgorithm, let roomID = content["room_id"]?.string,
              let sessionKey = content["session_key"]?.string, let senderKey = content["sender_key"]?.string,
              let sessionID = content["session_id"]?.string else { throw .badPayload("m.forwarded_room_key") }
        guard await hasKeyRequest(sessionID: sessionID, senderKey: senderKey) else { return }
        guard let device = try await devices(for: [userID]).first(where: { $0.curve25519Key == from }),
              await isVerified(device) else { return }
        let session: MegolmInboundSession
        do { session = try MegolmInboundSession(exportedKey: sessionKey) } catch { throw .crypto(error) }
        guard session.sessionID == sessionID else { throw .badPayload("session_id не совпал с ключом") }
        let claimed = content["sender_claimed_ed25519_key"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        try await storing {
            try await store.saveMegolmSession(session, roomID: roomID, senderKey: senderKey, claimedEd25519: claimed)
        }
        await settleKeyRequest(sessionID: sessionID, senderKey: senderKey)
    }

    // MARK: Отказы

    /// Отказ в ключе от отправителя: показать причину вместо «ждём ключ».
    func acceptWithheld(_ event: Event) async {
        let content = event.content
        guard content["algorithm"]?.string == Self.megolmAlgorithm, let code = content["code"]?.string,
              let sessionID = content["session_id"]?.string else { return }
        let senderKey = content["sender_key"]?.string ?? ""
        if (try? await store.megolmSession(sessionID: sessionID)) != nil { return }
        try? await store.saveWithheld(sessionID: sessionID, senderKey: senderKey, code: code,
                                      reason: content["reason"]?.string)
    }

    /// Сообщить устройствам, что ключ сессии им не придёт (`m.no_olm`: нет одноразовых ключей для канала Olm).
    func sendWithheld(_ devices: [DeviceInfo], roomID: String, sessionID: String, code: String,
                      reason: String) async throws(E2EEError) {
        guard !devices.isEmpty else { return }
        let content: JSONValue = [
            "algorithm": .string(Self.megolmAlgorithm), "room_id": .string(roomID), "session_id": .string(sessionID),
            "sender_key": .string(curve25519Key), "code": .string(code), "reason": .string(reason),
            "from_device": .string(deviceID),
        ]
        var messages: [String: [String: JSONValue]] = [:]
        for device in devices { messages[device.userID, default: [:]][device.deviceID] = content }
        do { try await client.sendToDevice(type: Self.withheldType, messages: messages) } catch { throw .server(error) }
    }
}
