// Нютаг. Olm: шифрование между двумя устройствами по спецификации Olm (matrix.org/docs/spec/olm).
// Установка сессии тройным Диффи–Хеллманом (3DH), дальше двойной храповик: корневой ключ обновляется
// при каждой смене ключа храповика собеседника, цепочки — HMAC-SHA-256 на каждое сообщение.

import Foundation

/// Обычное сообщение Olm (тип 1): версия 3, protobuf (ключ храповика, номер в цепочке, шифртекст), 8 байт MAC.
struct OlmMessage: Equatable {
    static let version: UInt8 = 3
    static let macLength = 8

    let ratchetKey: Data
    let chainIndex: UInt32
    let ciphertext: Data

    /// Байты до MAC.
    func body() -> Data {
        var out = Data([Self.version])
        out.append(0x0A)
        Protobuf.appendVarint(UInt64(ratchetKey.count), to: &out)
        out.append(ratchetKey)
        out.append(0x10)
        Protobuf.appendVarint(UInt64(chainIndex), to: &out)
        out.append(0x22)
        Protobuf.appendVarint(UInt64(ciphertext.count), to: &out)
        out.append(ciphertext)
        return out
    }

    static func parse(_ raw: Data) throws(CryptoError) -> (message: OlmMessage, body: Data, mac: Data) {
        let raw = Data(raw)
        guard raw.count > 1 + macLength, raw[0] == version else { throw .badMessage("olm: версия или длина") }
        let bodyEnd = raw.count - macLength
        var ratchetKey: Data?
        var index: UInt32?
        var ciphertext: Data?
        var reader = Protobuf.Reader(raw[1..<bodyEnd])
        while let (tag, value) = try reader.next() {
            switch (tag, value) {
            case (1, .bytes(let b)): ratchetKey = Data(b)
            case (2, .varint(let v)): index = UInt32(truncatingIfNeeded: v)
            case (4, .bytes(let b)): ciphertext = Data(b)
            default: break
            }
        }
        guard let ratchetKey, ratchetKey.count == 32, let index, let ciphertext else {
            throw .badMessage("olm: нет полей")
        }
        return (OlmMessage(ratchetKey: ratchetKey, chainIndex: index, ciphertext: ciphertext),
                Data(raw[0..<bodyEnd]), Data(raw[bodyEnd...]))
    }
}

/// Сообщение установки сессии (тип 0): одноразовый ключ получателя, базовый и долговременный ключи отправителя
/// и обычное сообщение внутри.
struct OlmPreKeyMessage: Equatable {
    let oneTimeKey: Data
    let baseKey: Data
    let identityKey: Data
    let message: Data

    func encode() -> Data {
        var out = Data([OlmMessage.version])
        for (tag, value) in [(UInt8(0x0A), oneTimeKey), (0x12, baseKey), (0x1A, identityKey), (0x22, message)] {
            out.append(tag)
            Protobuf.appendVarint(UInt64(value.count), to: &out)
            out.append(value)
        }
        return out
    }

    static func parse(_ raw: Data) throws(CryptoError) -> OlmPreKeyMessage {
        let raw = Data(raw)
        guard raw.count > 1, raw[0] == OlmMessage.version else { throw .badMessage("olm prekey: версия") }
        var fields: [Int: Data] = [:]
        var reader = Protobuf.Reader(raw[1...])
        while let (tag, value) = try reader.next() {
            if case .bytes(let b) = value { fields[tag] = Data(b) }
        }
        guard let oneTime = fields[1], oneTime.count == 32, let base = fields[2], base.count == 32,
              let identity = fields[3], identity.count == 32, let message = fields[4] else {
            throw .badMessage("olm prekey: нет полей")
        }
        return OlmPreKeyMessage(oneTimeKey: oneTime, baseKey: base, identityKey: identity, message: message)
    }
}

/// Зашифрованное сообщение Olm в виде поля `ciphertext[ключ].{type, body}`.
public struct OlmEncrypted: Sendable, Equatable, Codable {
    public enum Kind: Int, Sendable, Codable {
        case preKey = 0
        case normal = 1
    }

    public let type: Kind
    public let body: String

    public init(type: Kind, body: String) {
        self.type = type
        self.body = body
    }
}

/// Звено цепочки: ключ и номер следующего сообщения.
struct OlmChainKey: Codable, Equatable {
    var key: Data
    var index: UInt32

    func messageKey() -> Data { Hash.hmacSHA256(key: key, data: Data([1])) }

    mutating func advance() {
        key = Hash.hmacSHA256(key: key, data: Data([2]))
        index &+= 1
    }
}

/// Ключ пропущенного сообщения: сохраняем, чтобы расшифровать его, если оно придёт позже.
struct OlmSkippedKey: Codable, Equatable {
    let ratchetKey: Data
    let index: UInt32
    let key: Data
}

/// Сессия Olm с одним устройством собеседника.
public struct OlmSession: Sendable, Codable {
    static let maxReceiverChains = 5
    static let maxSkippedKeys = 40
    static let maxMessageGap: UInt32 = 2000

    /// Ключи установки: долговременный ключ инициатора, его базовый ключ, одноразовый ключ получателя.
    let aliceIdentityKey: Data
    let aliceBaseKey: Data
    let bobOneTimeKey: Data

    private var rootKey: Data
    private var senderRatchet: Curve25519KeyPair?
    private var senderChain: OlmChainKey?
    /// Новые в начале: ключ храповика собеседника и его цепочка.
    private var receiverChains: [(ratchetKey: Data, chain: OlmChainKey)]
    private var skippedKeys: [OlmSkippedKey]
    /// Пока собеседник нам не ответил, шлём сообщения установки (тип 0).
    public private(set) var receivedMessage: Bool
    /// Ключ собеседника (Curve25519, base64): с ним связана сессия.
    public let theirIdentityKey: String
    public private(set) var lastUsed: Date

    /// sha256(долговременный ключ инициатора ‖ базовый ключ ‖ одноразовый ключ получателя).
    public var sessionID: String {
        Base64.encodeUnpadded(Hash.sha256(aliceIdentityKey + aliceBaseKey + bobOneTimeKey))
    }

    // MARK: Установка

    /// Исходящая сессия (мы Алиса): нужен долговременный и одноразовый ключи собеседника из `/keys/claim`.
    public init(outboundFrom identity: Curve25519KeyPair, theirIdentityKey: Data,
                theirOneTimeKey: Data) throws(CryptoError) {
        guard theirIdentityKey.count == 32, theirOneTimeKey.count == 32 else { throw .badKeyLength }
        let base = Curve25519KeyPair()
        let ratchet = Curve25519KeyPair()
        let secret = try identity.sharedSecret(with: theirOneTimeKey)
            + base.sharedSecret(with: theirIdentityKey)
            + base.sharedSecret(with: theirOneTimeKey)
        let derived = Self.rootKDF(secret)
        aliceIdentityKey = identity.publicKey
        aliceBaseKey = base.publicKey
        bobOneTimeKey = theirOneTimeKey
        rootKey = derived.root
        senderRatchet = ratchet
        senderChain = OlmChainKey(key: derived.chain, index: 0)
        receiverChains = []
        skippedKeys = []
        receivedMessage = false
        self.theirIdentityKey = Base64.encodeUnpadded(theirIdentityKey)
        lastUsed = Date()
    }

    /// Входящая сессия (мы Боб) из сообщения установки. `oneTimeKey` — наш ключ, на который сослался отправитель.
    init(inboundFrom identity: Curve25519KeyPair, oneTimeKey: Curve25519KeyPair,
         preKey: OlmPreKeyMessage) throws(CryptoError) {
        let inner = try OlmMessage.parse(preKey.message).message
        let secret = try oneTimeKey.sharedSecret(with: preKey.identityKey)
            + identity.sharedSecret(with: preKey.baseKey)
            + oneTimeKey.sharedSecret(with: preKey.baseKey)
        let derived = Self.rootKDF(secret)
        aliceIdentityKey = preKey.identityKey
        aliceBaseKey = preKey.baseKey
        bobOneTimeKey = preKey.oneTimeKey
        rootKey = derived.root
        senderRatchet = nil
        senderChain = nil
        receiverChains = [(inner.ratchetKey, OlmChainKey(key: derived.chain, index: 0))]
        skippedKeys = []
        receivedMessage = false
        theirIdentityKey = Base64.encodeUnpadded(preKey.identityKey)
        lastUsed = Date()
    }

    private static func rootKDF(_ secret: Data) -> (root: Data, chain: Data) {
        let out = Hash.hkdfSHA256(ikm: secret, salt: Data(), info: Data("OLM_ROOT".utf8), outputByteCount: 64)
        return (out.prefix(32), out.suffix(32))
    }

    private static func ratchetKDF(root: Data, secret: Data) -> (root: Data, chain: Data) {
        let out = Hash.hkdfSHA256(ikm: secret, salt: root, info: Data("OLM_RATCHET".utf8), outputByteCount: 64)
        return (out.prefix(32), out.suffix(32))
    }

    private static func messageKeys(_ messageKey: Data) -> (aes: Data, mac: Data, iv: Data) {
        let out = Hash.hkdfSHA256(ikm: messageKey, salt: Data(), info: Data("OLM_KEYS".utf8), outputByteCount: 80)
        let base = out.startIndex
        return (out[base..<base + 32], out[base + 32..<base + 64], out[base + 64..<base + 80])
    }

    /// Подходит ли сообщение установки к этой сессии (повторы тип 0 до первого ответа).
    func matches(_ preKey: OlmPreKeyMessage) -> Bool {
        preKey.identityKey == aliceIdentityKey && preKey.baseKey == aliceBaseKey && preKey.oneTimeKey == bobOneTimeKey
    }

    /// Подходит ли сообщение установки (тип 0, base64) к этой сессии.
    public func matches(preKeyBody body: String) -> Bool {
        guard let raw = try? Base64.decode(body), let preKey = try? OlmPreKeyMessage.parse(raw) else { return false }
        return matches(preKey)
    }

    // MARK: Шифрование

    public mutating func encrypt(_ plaintext: Data) throws(CryptoError) -> OlmEncrypted {
        if senderChain == nil {
            // Собеседник сменил ключ храповика: делаем свой новый и шагаем корнем.
            guard let theirs = receiverChains.first?.ratchetKey else { throw .badMessage("olm: нет цепочки") }
            let ratchet = Curve25519KeyPair()
            let derived = Self.ratchetKDF(root: rootKey, secret: try ratchet.sharedSecret(with: theirs))
            rootKey = derived.root
            senderRatchet = ratchet
            senderChain = OlmChainKey(key: derived.chain, index: 0)
        }
        guard var chain = senderChain, let ratchet = senderRatchet else { throw .badMessage("olm: нет цепочки") }
        let keys = Self.messageKeys(chain.messageKey())
        let ciphertext = try AES.cbcEncrypt(key: keys.aes, iv: keys.iv, plaintext: plaintext)
        var raw = OlmMessage(ratchetKey: ratchet.publicKey, chainIndex: chain.index, ciphertext: ciphertext).body()
        raw.append(Hash.hmacSHA256(key: keys.mac, data: raw).prefix(OlmMessage.macLength))
        chain.advance()
        senderChain = chain
        lastUsed = Date()

        guard !receivedMessage else { return OlmEncrypted(type: .normal, body: Base64.encodeUnpadded(raw)) }
        let preKey = OlmPreKeyMessage(oneTimeKey: bobOneTimeKey, baseKey: aliceBaseKey,
                                      identityKey: aliceIdentityKey, message: raw)
        return OlmEncrypted(type: .preKey, body: Base64.encodeUnpadded(preKey.encode()))
    }

    // MARK: Расшифровка

    public mutating func decrypt(_ encrypted: OlmEncrypted) throws(CryptoError) -> Data {
        let raw = try Base64.decode(encrypted.body)
        switch encrypted.type {
        case .preKey:
            let preKey = try OlmPreKeyMessage.parse(raw)
            guard matches(preKey) else { throw .badMessage("olm: сообщение установки от другой сессии") }
            return try decrypt(message: preKey.message)
        case .normal:
            return try decrypt(message: raw)
        }
    }

    mutating func decrypt(message raw: Data) throws(CryptoError) -> Data {
        let (message, body, mac) = try OlmMessage.parse(raw)

        // Уже известная цепочка собеседника.
        if let position = receiverChains.firstIndex(where: { $0.ratchetKey == message.ratchetKey }) {
            var chain = receiverChains[position].chain
            if message.chainIndex < chain.index {
                guard let skipped = skippedKeys.firstIndex(where: {
                    $0.ratchetKey == message.ratchetKey && $0.index == message.chainIndex
                }) else { throw .unknownMessageIndex }
                let plaintext = try Self.open(body: body, mac: mac, ciphertext: message.ciphertext,
                                              messageKey: skippedKeys[skipped].key)
                skippedKeys.remove(at: skipped)
                finish()
                return plaintext
            }
            var skipped: [OlmSkippedKey] = []
            let plaintext = try Self.advance(&chain, to: message, body: body, mac: mac, skipped: &skipped)
            receiverChains[position].chain = chain
            remember(skipped)
            finish()
            return plaintext
        }

        // Новый ключ храповика собеседника: проверяем на копии и только после удачной расшифровки сохраняем.
        guard let ours = senderRatchet else { throw .badMessage("olm: неизвестная цепочка") }
        let derived = Self.ratchetKDF(root: rootKey, secret: try ours.sharedSecret(with: message.ratchetKey))
        var chain = OlmChainKey(key: derived.chain, index: 0)
        var skipped: [OlmSkippedKey] = []
        let plaintext = try Self.advance(&chain, to: message, body: body, mac: mac, skipped: &skipped)
        rootKey = derived.root
        receiverChains.insert((message.ratchetKey, chain), at: 0)
        if receiverChains.count > Self.maxReceiverChains { receiverChains.removeLast() }
        senderRatchet = nil
        senderChain = nil
        remember(skipped)
        finish()
        return plaintext
    }

    private mutating func finish() {
        receivedMessage = true
        lastUsed = Date()
    }

    private mutating func remember(_ keys: [OlmSkippedKey]) {
        skippedKeys.append(contentsOf: keys)
        if skippedKeys.count > Self.maxSkippedKeys { skippedKeys.removeFirst(skippedKeys.count - Self.maxSkippedKeys) }
    }

    /// Прогон цепочки до номера сообщения с запоминанием пропущенных ключей, затем проверка и расшифровка.
    private static func advance(_ chain: inout OlmChainKey, to message: OlmMessage, body: Data, mac: Data,
                                skipped: inout [OlmSkippedKey]) throws(CryptoError) -> Data {
        guard message.chainIndex >= chain.index else { throw .unknownMessageIndex }
        guard message.chainIndex - chain.index <= maxMessageGap else { throw .badMessage("olm: слишком большой разрыв") }
        var work = chain
        var pending: [OlmSkippedKey] = []
        while work.index < message.chainIndex {
            pending.append(OlmSkippedKey(ratchetKey: message.ratchetKey, index: work.index, key: work.messageKey()))
            work.advance()
        }
        let plaintext = try open(body: body, mac: mac, ciphertext: message.ciphertext, messageKey: work.messageKey())
        work.advance()
        chain = work
        skipped = Array(pending.suffix(maxSkippedKeys))
        return plaintext
    }

    private static func open(body: Data, mac: Data, ciphertext: Data, messageKey: Data) throws(CryptoError) -> Data {
        let keys = messageKeys(messageKey)
        let expected = Hash.hmacSHA256(key: keys.mac, data: body).prefix(OlmMessage.macLength)
        guard Data(expected).constantTimeEquals(mac) else { throw .badMAC }
        return try AES.cbcDecrypt(key: keys.aes, iv: keys.iv, ciphertext: ciphertext)
    }

    // MARK: Codable (кортежи в массиве Codable не умеют)

    private struct ReceiverChain: Codable {
        let ratchetKey: Data
        let chain: OlmChainKey
    }

    private enum CodingKeys: String, CodingKey {
        case aliceIdentityKey, aliceBaseKey, bobOneTimeKey, rootKey, senderRatchet, senderChain, receiverChains,
             skippedKeys, receivedMessage, theirIdentityKey, lastUsed
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        aliceIdentityKey = try c.decode(Data.self, forKey: .aliceIdentityKey)
        aliceBaseKey = try c.decode(Data.self, forKey: .aliceBaseKey)
        bobOneTimeKey = try c.decode(Data.self, forKey: .bobOneTimeKey)
        rootKey = try c.decode(Data.self, forKey: .rootKey)
        senderRatchet = try c.decodeIfPresent(Data.self, forKey: .senderRatchet).map { try Curve25519KeyPair(rawRepresentation: $0) }
        senderChain = try c.decodeIfPresent(OlmChainKey.self, forKey: .senderChain)
        receiverChains = try c.decode([ReceiverChain].self, forKey: .receiverChains).map { ($0.ratchetKey, $0.chain) }
        skippedKeys = try c.decode([OlmSkippedKey].self, forKey: .skippedKeys)
        receivedMessage = try c.decode(Bool.self, forKey: .receivedMessage)
        theirIdentityKey = try c.decode(String.self, forKey: .theirIdentityKey)
        lastUsed = try c.decode(Date.self, forKey: .lastUsed)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(aliceIdentityKey, forKey: .aliceIdentityKey)
        try c.encode(aliceBaseKey, forKey: .aliceBaseKey)
        try c.encode(bobOneTimeKey, forKey: .bobOneTimeKey)
        try c.encode(rootKey, forKey: .rootKey)
        try c.encodeIfPresent(senderRatchet?.rawRepresentation, forKey: .senderRatchet)
        try c.encodeIfPresent(senderChain, forKey: .senderChain)
        try c.encode(receiverChains.map { ReceiverChain(ratchetKey: $0.ratchetKey, chain: $0.chain) }, forKey: .receiverChains)
        try c.encode(skippedKeys, forKey: .skippedKeys)
        try c.encode(receivedMessage, forKey: .receivedMessage)
        try c.encode(theirIdentityKey, forKey: .theirIdentityKey)
        try c.encode(lastUsed, forKey: .lastUsed)
    }
}

/// Ключи устройства: долговременные Curve25519 и Ed25519, одноразовые ключи и запасной ключ.
public struct OlmAccount: Sendable, Codable {
    public static let maxOneTimeKeys = 100

    public let identity: Curve25519KeyPair
    public let signing: Ed25519KeyPair
    /// Номер для идентификатора одноразового ключа (`AAAAAQ` и т.п. в libolm; у нас просто счётчик).
    private var nextKeyID: UInt32
    private var oneTimeKeys: [String: Curve25519KeyPair]
    /// Ещё не отправленные на сервер одноразовые ключи.
    private var unpublished: Set<String>
    private var fallback: (id: String, key: Curve25519KeyPair, published: Bool)?
    private var previousFallback: (id: String, key: Curve25519KeyPair)?

    public init() {
        identity = Curve25519KeyPair()
        signing = Ed25519KeyPair()
        nextKeyID = 1
        oneTimeKeys = [:]
        unpublished = []
    }

    public var curve25519Key: String { identity.publicKeyBase64 }
    public var ed25519Key: String { signing.publicKeyBase64 }

    public func sign(_ message: Data) -> String { Base64.encodeUnpadded(signing.sign(message)) }

    public var storedOneTimeKeyCount: Int { oneTimeKeys.count }

    /// Новые одноразовые ключи; старые вытесняются, если их больше лимита.
    public mutating func generateOneTimeKeys(_ count: Int) {
        for _ in 0..<count {
            let id = Self.keyID(nextKeyID)
            nextKeyID += 1
            oneTimeKeys[id] = Curve25519KeyPair()
            unpublished.insert(id)
        }
        let excess = oneTimeKeys.count - Self.maxOneTimeKeys
        if excess > 0 {
            for id in oneTimeKeys.keys.sorted(by: Self.olderFirst).prefix(excess) {
                oneTimeKeys[id] = nil
                unpublished.remove(id)
            }
        }
    }

    /// Неопубликованные одноразовые ключи: идентификатор → открытый ключ base64.
    public var unpublishedOneTimeKeys: [String: String] {
        Dictionary(uniqueKeysWithValues: unpublished.compactMap { id in oneTimeKeys[id].map { (id, $0.publicKeyBase64) } })
    }

    /// Новый запасной ключ; прежний остаётся для ещё не дошедших сообщений.
    public mutating func generateFallbackKey() {
        if let fallback { previousFallback = (fallback.id, fallback.key) }
        let id = Self.keyID(nextKeyID)
        nextKeyID += 1
        fallback = (id, Curve25519KeyPair(), false)
    }

    public var unpublishedFallbackKey: (id: String, key: String)? {
        guard let fallback, !fallback.published else { return nil }
        return (fallback.id, fallback.key.publicKeyBase64)
    }

    /// После удачного `/keys/upload`.
    public mutating func markKeysPublished() {
        unpublished.removeAll()
        fallback?.published = true
    }

    public mutating func forgetPreviousFallbackKey() { previousFallback = nil }

    /// Исходящая сессия к устройству по ключам из `/keys/claim`.
    public func outboundSession(theirIdentityKey: String, theirOneTimeKey: String) throws(CryptoError) -> OlmSession {
        try OlmSession(outboundFrom: identity, theirIdentityKey: try Base64.decode(theirIdentityKey),
                       theirOneTimeKey: try Base64.decode(theirOneTimeKey))
    }

    /// Новая входящая сессия из сообщения установки (тип 0). Использованный одноразовый ключ удаляется,
    /// запасной остаётся. `theirIdentityKey` — `sender_key` события, он обязан совпасть с ключом в сообщении.
    public mutating func inboundSession(theirIdentityKey: String, preKeyBody: String) throws(CryptoError) -> (session: OlmSession, plaintext: Data) {
        let preKey = try OlmPreKeyMessage.parse(try Base64.decode(preKeyBody))
        guard Base64.encodeUnpadded(preKey.identityKey) == theirIdentityKey else {
            throw .badMessage("olm: ключ отправителя не совпал")
        }
        let used: (id: String?, key: Curve25519KeyPair)
        if let entry = oneTimeKeys.first(where: { $0.value.publicKey == preKey.oneTimeKey }) {
            used = (entry.key, entry.value)
        } else if let fallback, fallback.key.publicKey == preKey.oneTimeKey {
            used = (nil, fallback.key)
        } else if let previousFallback, previousFallback.key.publicKey == preKey.oneTimeKey {
            used = (nil, previousFallback.key)
        } else {
            throw .badMessage("olm: неизвестный одноразовый ключ")
        }
        var session = try OlmSession(inboundFrom: identity, oneTimeKey: used.key, preKey: preKey)
        let plaintext = try session.decrypt(message: preKey.message)
        if let id = used.id {
            oneTimeKeys[id] = nil
            unpublished.remove(id)
        }
        return (session, plaintext)
    }

    private static func keyID(_ number: UInt32) -> String {
        Base64.encodeUnpadded(withUnsafeBytes(of: number.bigEndian) { Data($0) })
    }

    private static func olderFirst(_ a: String, _ b: String) -> Bool {
        let number = { (id: String) -> UInt32 in
            ((try? Base64.decode(id)) ?? Data()).reduce(0) { $0 << 8 | UInt32($1) }
        }
        return number(a) < number(b)
    }

    // MARK: Codable

    private struct StoredKey: Codable {
        let id: String
        let key: Data
        var published: Bool?
    }

    private enum CodingKeys: String, CodingKey {
        case identity, signing, nextKeyID, oneTimeKeys, unpublished, fallback, previousFallback
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        identity = try Curve25519KeyPair(rawRepresentation: c.decode(Data.self, forKey: .identity))
        signing = try Ed25519KeyPair(rawRepresentation: c.decode(Data.self, forKey: .signing))
        nextKeyID = try c.decode(UInt32.self, forKey: .nextKeyID)
        var keys: [String: Curve25519KeyPair] = [:]
        for stored in try c.decode([StoredKey].self, forKey: .oneTimeKeys) {
            keys[stored.id] = try Curve25519KeyPair(rawRepresentation: stored.key)
        }
        oneTimeKeys = keys
        unpublished = try c.decode(Set<String>.self, forKey: .unpublished)
        if let stored = try c.decodeIfPresent(StoredKey.self, forKey: .fallback) {
            fallback = (stored.id, try Curve25519KeyPair(rawRepresentation: stored.key), stored.published ?? false)
        }
        if let stored = try c.decodeIfPresent(StoredKey.self, forKey: .previousFallback) {
            previousFallback = (stored.id, try Curve25519KeyPair(rawRepresentation: stored.key))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(identity.rawRepresentation, forKey: .identity)
        try c.encode(signing.rawRepresentation, forKey: .signing)
        try c.encode(nextKeyID, forKey: .nextKeyID)
        try c.encode(oneTimeKeys.map { StoredKey(id: $0.key, key: $0.value.rawRepresentation) }, forKey: .oneTimeKeys)
        try c.encode(unpublished, forKey: .unpublished)
        try c.encodeIfPresent(fallback.map { StoredKey(id: $0.id, key: $0.key.rawRepresentation, published: $0.published) },
                              forKey: .fallback)
        try c.encodeIfPresent(previousFallback.map { StoredKey(id: $0.id, key: $0.key.rawRepresentation) },
                              forKey: .previousFallback)
    }
}
