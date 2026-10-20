// Нютаг. Проверка своих устройств и собеседников по эмодзи (`m.sas.v1`) через to-device или в комнате:
// request → ready → start → accept → key ↔ key → люди сверяют эмодзи → mac ↔ mac → done.
// В комнате (так собеседника проверяет Element) запрос — сообщение `m.key.verification.request`, его event_id
// служит id проверки, остальные события ссылаются на него через `m.relates_to` (`m.reference`).
// Итог: своё устройство подписывается ключом самоподписи, мастер-ключ собеседника — ключом подписи пользователей.

import Foundation
import NyutagCrypto

/// Проверка, как её видит интерфейс.
public struct VerificationFlow: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        /// Запрос ушёл (или пришёл), ответа ещё нет.
        case requested
        /// Обе стороны готовы, можно начинать сверку.
        case ready
        /// Идёт обмен ключами.
        case started
        /// Эмодзи готовы: человек сравнивает их с экраном другого устройства.
        case comparing
        /// Человек подтвердил совпадение, ждём подтверждения с другой стороны.
        case confirmed
        case done
        case cancelled(code: String, reason: String)
    }

    public let transactionID: String
    public let otherUserID: String
    public internal(set) var otherDeviceID: String?
    /// Запрос пришёл к нам, а не от нас.
    public let incoming: Bool
    public internal(set) var state: State
    /// Номера эмодзи в `SasEmoji.table` и три числа: появляются в состоянии `comparing`.
    public internal(set) var emoji: [Int]?
    public internal(set) var decimals: [Int]?
    /// Комната, в которой идёт проверка; nil — проверка через to-device.
    public internal(set) var roomID: String? = nil
}

/// Внутреннее состояние проверки: ключ SAS живёт только в памяти.
struct VerificationSession {
    var flow: VerificationFlow
    /// Устройства, которым ушёл запрос (кроме выбранного, им потом уйдёт отмена).
    var requestedDevices: [String] = []
    let sas = Sas()
    var established: EstablishedSas?
    var weStarted = false
    var startContent: JSONValue?
    var commitment: String?
    var keySent = false
    var theirKey: String?
    var theirMac: JSONValue?
}

enum VerificationEvent {
    static let request = "m.key.verification.request"
    static let ready = "m.key.verification.ready"
    static let start = "m.key.verification.start"
    static let accept = "m.key.verification.accept"
    static let key = "m.key.verification.key"
    static let mac = "m.key.verification.mac"
    static let done = "m.key.verification.done"
    static let cancel = "m.key.verification.cancel"
    static let all: Set<String> = [request, ready, start, accept, key, mac, done, cancel]
    /// Запросы старше этого (или «из будущего» больше чем на 5 минут) не показываем.
    static let requestLifetime = 10 * 60 * 1000

    static let sas = "m.sas.v1"
    static let keyAgreement = "curve25519-hkdf-sha256"
    static let hash = "sha256"
    static let macMethod = "hkdf-hmac-sha256.v2"
}

extension CryptoMachine {
    public func verification(_ transactionID: String) -> VerificationFlow? { verifications[transactionID]?.flow }

    public var verificationFlows: [VerificationFlow] { verifications.values.map(\.flow) }

    // MARK: Действия человека

    /// Попросить проверку у пользователя: у всех его устройств (у себя — кроме этого) или у перечисленных.
    /// Возвращает id проверки.
    public func requestVerification(userID other: String, deviceIDs: [String]? = nil) async throws(E2EEError) -> String {
        let targets = try await devices(for: [other]).map(\.deviceID).filter {
            (other != userID || $0 != deviceID) && deviceIDs?.contains($0) != false
        }
        guard !targets.isEmpty else { throw .badPayload("у \(other) нет устройств для проверки") }
        let transactionID = TransactionID.make()
        let content: JSONValue = [
            "from_device": .string(deviceID), "methods": [.string(VerificationEvent.sas)],
            "timestamp": .int(Int(Date().timeIntervalSince1970 * 1000)), "transaction_id": .string(transactionID),
        ]
        do {
            try await client.sendToDevice(type: VerificationEvent.request,
                                          messages: [other: Dictionary(uniqueKeysWithValues: targets.map { ($0, content) })])
        } catch {
            throw .server(error)
        }
        var session = VerificationSession(flow: VerificationFlow(transactionID: transactionID, otherUserID: other,
                                                                 incoming: false, state: .requested))
        session.requestedDevices = targets
        verifications[transactionID] = session
        return transactionID
    }

    /// Попросить собеседника о проверке в комнате (обычно в личном чате). Возвращает id проверки: event_id запроса.
    public func requestVerification(userID other: String, inRoom roomID: String) async throws(E2EEError) -> String {
        guard other != userID else { throw .badPayload("свои устройства проверяются через to-device") }
        let content: JSONValue = [
            "msgtype": .string(VerificationEvent.request), "to": .string(other), "from_device": .string(deviceID),
            "methods": [.string(VerificationEvent.sas)],
            "body": .string("\(userID) просит проверить ключи шифрования. Ваш клиент не поддерживает проверку в чате."),
        ]
        let transactionID = try await sendRoomEvent(roomID: roomID, type: EventType.message, content: content)
        verifications[transactionID] = VerificationSession(flow: VerificationFlow(
            transactionID: transactionID, otherUserID: other, incoming: false, state: .requested, roomID: roomID))
        return transactionID
    }

    /// Согласиться на пришедший запрос.
    public func acceptVerification(_ transactionID: String) async throws(E2EEError) {
        guard var session = verifications[transactionID], session.flow.incoming, session.flow.state == .requested
        else { throw .badPayload("нечего принимать") }
        try await send(VerificationEvent.ready, ["from_device": .string(deviceID), "methods": [.string(VerificationEvent.sas)]],
                       session)
        session.flow.state = .ready
        verifications[transactionID] = session
    }

    /// Начать сверку эмодзи (после `ready`; начать может любая сторона).
    public func startSas(_ transactionID: String) async throws(E2EEError) {
        guard var session = verifications[transactionID], session.flow.state == .ready
        else { throw .badPayload("проверка не готова") }
        let content: JSONValue = [
            "from_device": .string(deviceID), "method": .string(VerificationEvent.sas),
            "key_agreement_protocols": [.string(VerificationEvent.keyAgreement)],
            "hashes": [.string(VerificationEvent.hash)],
            "message_authentication_codes": [.string(VerificationEvent.macMethod)],
            "short_authentication_string": ["decimal", "emoji"], "transaction_id": .string(transactionID),
        ]
        // Обязательство считается от start в том виде, в каком его получила другая сторона.
        let sent = try await send(VerificationEvent.start, content, session)
        session.weStarted = true
        session.startContent = sent
        session.flow.state = .started
        verifications[transactionID] = session
    }

    /// Эмодзи совпали: отправить MAC своих ключей. Если MAC другой стороны уже пришёл, проверить его.
    public func confirmSas(_ transactionID: String) async throws(E2EEError) {
        guard var session = verifications[transactionID], session.flow.state == .comparing,
              let established = session.established, let otherDevice = session.flow.otherDeviceID
        else { throw .badPayload("сверять нечего") }
        var keys: [String: String] = ["ed25519:\(deviceID)": ed25519Key]
        if let master = try await ownCrossSigningKey(.master)?.publicKeyBase64 { keys["ed25519:\(master)"] = master }
        let base = "MATRIX_KEY_VERIFICATION_MAC" + userID + deviceID + session.flow.otherUserID + otherDevice + transactionID
        var mac: [String: JSONValue] = [:]
        for (id, key) in keys { mac[id] = .string(established.calculateMac(key, info: base + id)) }
        let keyIDs = keys.keys.sorted().joined(separator: ",")
        try await send(VerificationEvent.mac, ["mac": .object(mac),
                                               "keys": .string(established.calculateMac(keyIDs, info: base + "KEY_IDS"))],
                       session)
        session.flow.state = .confirmed
        verifications[transactionID] = session
        if session.theirMac != nil { try await checkMac(transactionID) }
    }

    /// Отказаться: эмодзи не совпали (`m.mismatched_sas`) или человек передумал (`m.user`).
    public func cancelVerification(_ transactionID: String, code: String = "m.user",
                                   reason: String = "Отменено пользователем") async {
        guard let session = verifications[transactionID] else { return }
        await cancel(session, code: code, reason: reason)
    }

    // MARK: Входящие события

    func receiveVerification(_ event: Event) async {
        guard let transactionID = event.content["transaction_id"]?.string else { return }
        await receiveVerification(event, transactionID: transactionID, roomID: nil)
    }

    /// События проверки из таймлайнов комнат; зашифрованные сначала расшифровываются.
    func receiveRoomVerifications(_ events: [Event], roomID: String) async {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        for var event in events {
            // Старые события (первая синхронизация, догрузка истории) живых проверок не касаются.
            guard let ts = event.originServerTS, now - ts < VerificationEvent.requestLifetime else { continue }
            if event.type == EventType.encrypted {
                guard let decrypted = try? await decrypt(event, roomID: roomID) else { continue }
                event = decrypted.event
            }
            await receiveRoomVerification(event, roomID: roomID)
        }
    }

    func receiveRoomVerification(_ event: Event, roomID: String) async {
        let content = event.content
        guard let sender = event.sender else { return }
        if event.type == EventType.message {
            guard content["msgtype"]?.string == VerificationEvent.request, let eventID = event.eventID,
                  sender != userID, content["to"]?.string == userID else { return }
            return receiveRequest(content, sender: sender, transactionID: eventID, timestamp: event.originServerTS,
                                  roomID: roomID)
        }
        guard VerificationEvent.all.contains(event.type), event.type != VerificationEvent.request,
              content["m.relates_to", "rel_type"]?.string == "m.reference",
              let transactionID = content["m.relates_to", "event_id"]?.string,
              var session = verifications[transactionID], session.flow.roomID == roomID else { return }
        if sender == userID {
            // Наше эхо пропускаем; если на запрос ответило другое наше устройство, здесь проверка закончена.
            if session.flow.incoming, session.flow.state == .requested, event.type == VerificationEvent.ready,
               content["from_device"]?.string != deviceID {
                session.flow.state = .cancelled(code: "m.accepted", reason: "Проверку приняло другое устройство")
                verifications[transactionID] = session
            }
            return
        }
        await receiveVerification(event, transactionID: transactionID, roomID: roomID)
    }

    private func receiveVerification(_ event: Event, transactionID: String, roomID: String?) async {
        let content = event.content
        guard let sender = event.sender else { return }
        if event.type == VerificationEvent.request {
            receiveRequest(content, sender: sender, transactionID: transactionID, timestamp: content["timestamp"]?.int,
                           roomID: nil)
            return
        }
        guard var session = verifications[transactionID], session.flow.otherUserID == sender,
              session.flow.roomID == roomID else { return }
        if case .cancelled = session.flow.state { return }
        if session.flow.state == .done { return }
        switch event.type {
        case VerificationEvent.cancel:
            session.flow.state = .cancelled(code: content["code"]?.string ?? "m.unknown",
                                            reason: content["reason"]?.string ?? "")
            verifications[transactionID] = session
        case VerificationEvent.ready:
            guard !session.flow.incoming, session.flow.state == .requested,
                  let from = content["from_device"]?.string,
                  session.flow.roomID != nil || session.requestedDevices.contains(from),
                  content["methods"]?.array?.contains(.string(VerificationEvent.sas)) == true
            else { return await unexpected(session) }
            session.flow.otherDeviceID = from
            session.flow.state = .ready
            verifications[transactionID] = session
            // Остальным устройствам: проверку взяло другое.
            let others = session.requestedDevices.filter { $0 != from }
            if !others.isEmpty {
                let cancel: JSONValue = ["transaction_id": .string(transactionID), "code": "m.accepted",
                                         "reason": "Проверку приняло другое устройство"]
                try? await client.sendToDevice(type: VerificationEvent.cancel, messages: [
                    sender: Dictionary(uniqueKeysWithValues: others.map { ($0, cancel) }),
                ])
            }
        case VerificationEvent.start:
            await receiveStart(content, session: session)
        case VerificationEvent.accept:
            guard session.weStarted, session.flow.state == .started, session.commitment == nil,
                  content["key_agreement_protocol"]?.string == VerificationEvent.keyAgreement,
                  content["hash"]?.string == VerificationEvent.hash,
                  content["message_authentication_code"]?.string == VerificationEvent.macMethod,
                  let commitment = content["commitment"]?.string else { return await unexpected(session) }
            session.commitment = commitment
            verifications[transactionID] = session
            await sendKey(transactionID)
        case VerificationEvent.key:
            await receiveKey(content, session: session)
        case VerificationEvent.mac:
            guard session.flow.state == .comparing || session.flow.state == .confirmed, session.theirMac == nil
            else { return await unexpected(session) }
            session.theirMac = content
            verifications[transactionID] = session
            if session.flow.state == .confirmed { try? await checkMac(transactionID) }
        default:
            break
        }
    }

    private func receiveRequest(_ content: JSONValue, sender: String, transactionID: String, timestamp: Int?,
                                roomID: String?) {
        guard verifications[transactionID] == nil, let from = content["from_device"]?.string,
              sender != userID || from != deviceID,
              content["methods"]?.array?.contains(.string(VerificationEvent.sas)) == true,
              let timestamp else { return }
        // Старые и «из будущего» запросы не показываем.
        let age = Int(Date().timeIntervalSince1970 * 1000) - timestamp
        guard age < VerificationEvent.requestLifetime, age > -5 * 60 * 1000 else { return }
        verifications[transactionID] = VerificationSession(flow: VerificationFlow(
            transactionID: transactionID, otherUserID: sender, otherDeviceID: from, incoming: true, state: .requested,
            roomID: roomID))
    }

    private func receiveStart(_ content: JSONValue, session: VerificationSession) async {
        var session = session
        let transactionID = session.flow.transactionID
        guard content["from_device"]?.string == session.flow.otherDeviceID,
              session.flow.state == .ready || (session.flow.state == .started && session.weStarted)
        else { return await unexpected(session) }
        if session.weStarted {
            // Начали обе стороны сразу: остаётся start того, чей user_id (затем device_id) меньше.
            let mine = (userID, deviceID), theirs = (session.flow.otherUserID, session.flow.otherDeviceID ?? "")
            if mine < theirs { return }
        }
        guard content["method"]?.string == VerificationEvent.sas,
              content["key_agreement_protocols"]?.array?.contains(.string(VerificationEvent.keyAgreement)) == true,
              content["hashes"]?.array?.contains(.string(VerificationEvent.hash)) == true,
              content["message_authentication_codes"]?.array?.contains(.string(VerificationEvent.macMethod)) == true
        else { return await cancel(session, code: "m.unknown_method", reason: "Нет общего способа проверки") }
        let modes = (content["short_authentication_string"]?.array ?? []).filter { $0 == "emoji" || $0 == "decimal" }
        guard modes.contains("decimal") else {
            return await cancel(session, code: "m.unknown_method", reason: "Нет общего способа проверки")
        }
        let commitment = Base64.encodeUnpadded(Hash.sha256(Data((session.sas.publicKeyBase64 + content.canonicalJSON()).utf8)))
        let accept: JSONValue = [
            "method": .string(VerificationEvent.sas), "key_agreement_protocol": .string(VerificationEvent.keyAgreement),
            "hash": .string(VerificationEvent.hash), "message_authentication_code": .string(VerificationEvent.macMethod),
            "short_authentication_string": .array(modes), "commitment": .string(commitment),
        ]
        do { try await send(VerificationEvent.accept, accept, session) } catch { return }
        session.weStarted = false
        session.startContent = content
        session.flow.state = .started
        verifications[transactionID] = session
    }

    private func receiveKey(_ content: JSONValue, session: VerificationSession) async {
        var session = session
        let transactionID = session.flow.transactionID
        guard session.flow.state == .started, session.theirKey == nil, let key = content["key"]?.string,
              let startContent = session.startContent else { return await unexpected(session) }
        if session.weStarted {
            // Мы начали: другая сторона заранее обязалась ключом в accept.
            guard session.keySent, let commitment = session.commitment else { return await unexpected(session) }
            let expected = Base64.encodeUnpadded(Hash.sha256(Data((key + startContent.canonicalJSON()).utf8)))
            guard expected == commitment else {
                return await cancel(session, code: "m.mismatched_commitment", reason: "Ключ не совпал с обязательством")
            }
        } else if session.keySent {
            return await unexpected(session)
        }
        guard let established = try? session.sas.establish(theirPublicKey: key), let other = session.flow.otherDeviceID
        else { return await cancel(session, code: "m.invalid_message", reason: "Неверный ключ") }
        session.theirKey = key
        session.established = established
        verifications[transactionID] = session
        if !session.weStarted {
            await sendKey(transactionID)
            guard let sent = verifications[transactionID], sent.keySent else { return }
            session = sent
        }
        let ours = (userID, deviceID, session.sas.publicKeyBase64), theirs = (session.flow.otherUserID, other, key)
        let (starter, accepter) = session.weStarted ? (ours, theirs) : (theirs, ours)
        let info = ["MATRIX_KEY_VERIFICATION_SAS", starter.0, starter.1, starter.2, accepter.0, accepter.1, accepter.2,
                    transactionID].joined(separator: "|")
        session.flow.emoji = established.emojiIndices(info: info)
        session.flow.decimals = established.decimals(info: info)
        session.flow.state = .comparing
        verifications[transactionID] = session
    }

    private func sendKey(_ transactionID: String) async {
        guard var session = verifications[transactionID] else { return }
        do { try await send(VerificationEvent.key, ["key": .string(session.sas.publicKeyBase64)], session) } catch { return }
        session.keySent = true
        verifications[transactionID] = session
    }

    /// Проверить MAC другой стороны и довериться её ключам: подписать устройство или мастер-ключ.
    private func checkMac(_ transactionID: String) async throws(E2EEError) {
        guard let session = verifications[transactionID], let content = session.theirMac,
              let established = session.established, let otherDevice = session.flow.otherDeviceID else { return }
        let other = session.flow.otherUserID
        let base = "MATRIX_KEY_VERIFICATION_MAC" + other + otherDevice + userID + deviceID + transactionID
        guard let macs = content["mac"]?.object, let keysMac = content["keys"]?.string,
              established.calculateMac(macs.keys.sorted().joined(separator: ","), info: base + "KEY_IDS") == keysMac
        else { return await cancel(session, code: "m.key_mismatch", reason: "Список ключей не совпал") }
        guard let device = try await devices(for: [other]).first(where: { $0.deviceID == otherDevice })
        else { return await cancel(session, code: "m.key_mismatch", reason: "Устройство не найдено") }
        let identity = try await storing { try await store.crossSigning(userID: other) }
        var deviceOK = false, masterKey: String?
        for (id, value) in macs {
            let key: String
            if id == "ed25519:\(otherDevice)" {
                key = device.ed25519Key
            } else if let master = identity?.masterKey, id == "ed25519:\(master)" {
                key = master
            } else {
                continue
            }
            guard value.string == established.calculateMac(key, info: base + id) else {
                return await cancel(session, code: "m.key_mismatch", reason: "Ключи не совпали")
            }
            if key == device.ed25519Key { deviceOK = true } else { masterKey = key }
        }
        guard deviceOK else { return await cancel(session, code: "m.key_mismatch", reason: "Нет ключа устройства") }

        // Подписать нечем — доверяем устройству на этом устройстве. Своё новое устройство без ключей кросс-подписи
        // тут же просит их (и ключ бэкапа) у только что проверенного.
        if other == userID, try await ownCrossSigningKey(.selfSigning) != nil {
            try await signDevice(device)
        } else if other != userID, let masterKey, try await ownCrossSigningKey(.userSigning) != nil {
            try await signUser(other, masterKey: masterKey)
        } else {
            try await trustLocally(device)
        }
        try await send(VerificationEvent.done, [:], session)
        if other == userID, try await ownCrossSigningKey(.selfSigning) == nil { try await requestSecrets(from: device) }
        var finished = session
        finished.flow.state = .done
        verifications[transactionID] = finished
    }

    // MARK: Подписи

    /// Подписать своё другое устройство ключом самоподписи.
    func signDevice(_ device: DeviceInfo) async throws(E2EEError) {
        guard let selfSigning = try await ownCrossSigningKey(.selfSigning) else { throw .noBackup }
        let response: JSONValue
        do { response = try await client.queryKeys(userIDs: [userID]) } catch { throw .server(error) }
        guard let keys = response["device_keys", userID, device.deviceID],
              keys["keys", "ed25519:\(device.deviceID)"]?.string == device.ed25519Key
        else { throw .badPayload("ключи устройства на сервере изменились") }
        let signed = Self.signed(Self.withoutSignatures(keys), userID: userID, keyID: selfSigning.publicKeyBase64,
                                 with: selfSigning)
        try await uploadSignature(user: userID, keyID: device.deviceID, signed)
    }

    /// Подписать мастер-ключ собеседника своим ключом подписи пользователей.
    func signUser(_ other: String, masterKey: String) async throws(E2EEError) {
        guard let userSigning = try await ownCrossSigningKey(.userSigning) else { throw .noBackup }
        let response: JSONValue
        do { response = try await client.queryKeys(userIDs: [other]) } catch { throw .server(error) }
        guard let master = response["master_keys", other],
              Self.crossSigningPublicKey(master, userID: other, usage: "master") == masterKey
        else { throw .badPayload("мастер-ключ собеседника на сервере изменился") }
        let signed = Self.signed(Self.withoutSignatures(master), userID: userID, keyID: userSigning.publicKeyBase64,
                                 with: userSigning)
        try await uploadSignature(user: other, keyID: masterKey, signed)
    }

    private func uploadSignature(user: String, keyID: String, _ signed: JSONValue) async throws(E2EEError) {
        let failures: JSONValue
        do { failures = try await client.uploadSignatures([user: [keyID: signed]]) } catch { throw .server(error) }
        if let failure = failures[user, keyID] {
            throw .badPayload("подпись отклонена: \(failure["errcode"]?.string ?? "")")
        }
        try await storing { try await store.markDeviceListsChanged([user]) }
    }

    static func withoutSignatures(_ object: JSONValue) -> JSONValue {
        guard case .object(var fields) = object else { return object }
        fields["signatures"] = nil
        fields["unsigned"] = nil
        return .object(fields)
    }

    // MARK: Отправка

    /// Отправить событие проверки. Возвращает содержимое в том виде, в каком оно ушло.
    @discardableResult
    private func send(_ type: String, _ content: JSONValue, _ session: VerificationSession) async throws(E2EEError) -> JSONValue {
        guard case .object(var fields) = content else { throw .badPayload("содержимое проверки не объект") }
        if let roomID = session.flow.roomID {
            fields["m.relates_to"] = ["rel_type": "m.reference", "event_id": .string(session.flow.transactionID)]
            _ = try await sendRoomEvent(roomID: roomID, type: type, content: .object(fields))
            return .object(fields)
        }
        guard let device = session.flow.otherDeviceID else { throw .badPayload("нет устройства собеседника") }
        fields["transaction_id"] = .string(session.flow.transactionID)
        do {
            try await client.sendToDevice(type: type, messages: [session.flow.otherUserID: [device: .object(fields)]])
        } catch {
            throw .server(error)
        }
        return .object(fields)
    }

    /// Событие в комнату: в зашифрованной (или неизвестной локально) — через Megolm.
    private func sendRoomEvent(roomID: String, type: String, content: JSONValue) async throws(E2EEError) -> String {
        let record = try await storing { try await store.room(roomID) }
        if record?.isEncrypted ?? true { return try await sendEncrypted(roomID: roomID, type: type, content: content) }
        do { return try await client.send(roomID: roomID, type: type, content: content) } catch { throw .server(error) }
    }

    private func unexpected(_ session: VerificationSession) async {
        await cancel(session, code: "m.unexpected_message", reason: "Неожиданное сообщение проверки")
    }

    private func cancel(_ session: VerificationSession, code: String, reason: String) async {
        var session = session
        let content: JSONValue = ["transaction_id": .string(session.flow.transactionID), "code": .string(code),
                                  "reason": .string(reason)]
        let targets = session.flow.otherDeviceID.map { [$0] } ?? session.requestedDevices
        if session.flow.roomID != nil {
            try? await send(VerificationEvent.cancel, ["code": .string(code), "reason": .string(reason)], session)
        } else if !targets.isEmpty {
            try? await client.sendToDevice(type: VerificationEvent.cancel, messages: [
                session.flow.otherUserID: Dictionary(uniqueKeysWithValues: targets.map { ($0, content) }),
            ])
        }
        session.flow.state = .cancelled(code: code, reason: reason)
        verifications[session.flow.transactionID] = session
    }
}
