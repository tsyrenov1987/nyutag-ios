// Нютаг. Megolm: групповой храповик комнаты по спецификации Olm/Megolm (matrix.org/docs/spec/megolm).
// Храповик из четырёх 32-байтных частей R0…R3 и 32-битного счётчика; части обновляются HMAC-SHA-256
// с номером части как сообщением. Ключи сообщения: HKDF-SHA-256(R, info "MEGOLM_KEYS") → AES-256 32 + HMAC 32 + IV 16.

import Foundation

/// Состояние храповика: 128 байт и счётчик.
public struct MegolmRatchet: Sendable, Equatable {
    public static let partLength = 32
    public static let parts = 4
    public static let length = partLength * parts

    public private(set) var data: Data
    public private(set) var counter: UInt32

    public init(data: Data, counter: UInt32) throws(CryptoError) {
        guard data.count == Self.length else { throw .badKeyLength }
        self.data = Data(data)
        self.counter = counter
    }

    /// Свежий случайный храповик для новой исходящей сессии.
    public static func random() -> MegolmRatchet {
        try! MegolmRatchet(data: Random.bytes(length), counter: 0)
    }

    private func part(_ index: Int) -> Data {
        let start = data.startIndex + index * Self.partLength
        return data[start..<start + Self.partLength]
    }

    /// R(to) = HMAC(ключ R(from), байт to).
    private mutating func rehash(from: Int, to: Int) {
        let next = Hash.hmacSHA256(key: Data(part(from)), data: Data([UInt8(to)]))
        let start = data.startIndex + to * Self.partLength
        data.replaceSubrange(start..<start + Self.partLength, with: next)
    }

    /// Шаг на одно сообщение вперёд.
    public mutating func advance() {
        var mask: UInt32 = 0x00FF_FFFF
        var h = 0
        counter &+= 1
        while h < Self.parts {
            if counter & mask == 0 { break }
            h += 1
            mask >>= 8
        }
        for i in stride(from: Self.parts - 1, through: h, by: -1) {
            rehash(from: h, to: i)
        }
    }

    /// Переход сразу к индексу без пошагового прохода (как `megolm_advance_to` в эталонной реализации).
    public mutating func advance(to target: UInt32) {
        for j in 0..<Self.parts {
            let shift = UInt32((Self.parts - j - 1) * 8)
            let mask = UInt32.max << shift
            var steps = ((target >> shift) &- (counter >> shift)) & 0xFF
            if steps == 0 {
                // Счётчик чуть больше цели только при переполнении R0: прокрутить его 256 раз.
                if target < counter { steps = 0x100 } else { continue }
            }
            while steps > 1 {
                rehash(from: j, to: j)
                steps -= 1
            }
            for k in stride(from: Self.parts - 1, through: j, by: -1) {
                rehash(from: j, to: k)
            }
            counter = target & mask
        }
    }

    /// AES-ключ, HMAC-ключ и IV текущего сообщения.
    func messageKeys() -> (aes: Data, mac: Data, iv: Data) {
        let keys = Hash.hkdfSHA256(ikm: data, salt: Data(), info: Data("MEGOLM_KEYS".utf8), outputByteCount: 80)
        let base = keys.startIndex
        return (keys[base..<base + 32], keys[base + 32..<base + 64], keys[base + 64..<base + 80])
    }
}

/// Сообщение Megolm в двоичном виде: версия 3, поля protobuf (индекс, шифртекст), 8 байт MAC, 64 байта подписи.
public struct MegolmMessage: Sendable, Equatable {
    public static let version: UInt8 = 3
    public static let macLength = 8
    public static let signatureLength = 64

    public let messageIndex: UInt32
    public let ciphertext: Data

    /// Байты до MAC (их и подписывает, вместе с MAC, ключ отправителя).
    static func body(index: UInt32, ciphertext: Data) -> Data {
        var out = Data([version])
        out.append(0x08)
        Protobuf.appendVarint(UInt64(index), to: &out)
        out.append(0x12)
        Protobuf.appendVarint(UInt64(ciphertext.count), to: &out)
        out.append(ciphertext)
        return out
    }

    /// Разбор без проверки MAC и подписи; возвращает ещё и границы частей для проверок.
    static func parse(_ raw: Data) throws(CryptoError) -> (message: MegolmMessage, body: Data, mac: Data, signature: Data) {
        let raw = Data(raw)
        guard raw.count > 1 + macLength + signatureLength, raw[0] == version else { throw .badMessage("версия или длина") }
        let bodyEnd = raw.count - macLength - signatureLength
        let body = raw[0..<bodyEnd]
        var index: UInt32?
        var ciphertext: Data?
        var reader = Protobuf.Reader(raw[1..<bodyEnd])
        while let (tag, value) = try reader.next() {
            switch (tag, value) {
            case (1, .varint(let v)): index = UInt32(truncatingIfNeeded: v)
            case (2, .bytes(let b)): ciphertext = b
            default: break
            }
        }
        guard let index, let ciphertext else { throw .badMessage("нет индекса или шифртекста") }
        return (MegolmMessage(messageIndex: index, ciphertext: ciphertext), Data(body),
                raw[bodyEnd..<bodyEnd + macLength], raw[(bodyEnd + macLength)...])
    }
}

/// Исходящая сессия: шифрует наши сообщения в комнату. Ключ подписи Ed25519 — имя сессии (session_id).
public struct MegolmOutboundSession: Sendable {
    public private(set) var ratchet: MegolmRatchet
    public let signingKey: Ed25519KeyPair
    public let createdAt: Date

    public init() {
        ratchet = .random()
        signingKey = Ed25519KeyPair()
        createdAt = Date()
    }

    public init(ratchet: MegolmRatchet, signingKey: Ed25519KeyPair, createdAt: Date) {
        self.ratchet = ratchet
        self.signingKey = signingKey
        self.createdAt = createdAt
    }

    public var sessionID: String { signingKey.publicKeyBase64 }
    public var messageIndex: UInt32 { ratchet.counter }

    /// Шифрует и сдвигает храповик. Результат — base64 без паддинга для поля `ciphertext`.
    public mutating func encrypt(_ plaintext: Data) throws(CryptoError) -> String {
        let keys = ratchet.messageKeys()
        let ciphertext = try AES.cbcEncrypt(key: keys.aes, iv: keys.iv, plaintext: plaintext)
        var message = MegolmMessage.body(index: ratchet.counter, ciphertext: ciphertext)
        message.append(Hash.hmacSHA256(key: keys.mac, data: message).prefix(MegolmMessage.macLength))
        message.append(signingKey.sign(message))
        ratchet.advance()
        return Base64.encodeUnpadded(message)
    }

    /// `session_key` для события `m.room_key`: версия 2, счётчик, храповик, ключ подписи и подпись всего этого.
    public func sessionKey() -> String {
        var out = Data([2])
        out.append(contentsOf: withUnsafeBytes(of: ratchet.counter.bigEndian, Array.init))
        out.append(ratchet.data)
        out.append(signingKey.publicKey)
        out.append(signingKey.sign(out))
        return Base64.encodeUnpadded(out)
    }
}

/// Входящая сессия: расшифровывает сообщения одного отправителя в комнате.
public struct MegolmInboundSession: Sendable {
    /// Самый ранний известный храповик (с него можно расшифровать всё, начиная с его индекса).
    public let initialRatchet: MegolmRatchet
    /// Ключ подписи сессии; он же session_id в base64.
    public let signingKey: Data
    /// Пришла ли сессия с подписью отправителя (`m.room_key`), а не из бэкапа или пересылки.
    public let isVerified: Bool

    public var sessionID: String { Base64.encodeUnpadded(signingKey) }
    public var firstKnownIndex: UInt32 { initialRatchet.counter }

    /// Из `session_key` события `m.room_key` (версия 2, с подписью).
    public init(sessionKey: String) throws(CryptoError) {
        let raw = try Base64.decode(sessionKey)
        guard raw.count == 1 + 4 + MegolmRatchet.length + 32 + 64, raw.first == 2 else { throw .badMessage("session_key") }
        let signedEnd = raw.count - 64
        let key = raw[(1 + 4 + MegolmRatchet.length)..<signedEnd]
        guard Ed25519KeyPair.verify(signature: raw[signedEnd...], message: raw[..<signedEnd], publicKey: Data(key)) else {
            throw .badSignature
        }
        try self.init(raw: raw, version: 2, verified: true)
    }

    /// Из выгрузки (`m.forwarded_room_key`, бэкап ключей): версия 1, без подписи.
    public init(exportedKey: String) throws(CryptoError) {
        let raw = try Base64.decode(exportedKey)
        guard raw.count == 1 + 4 + MegolmRatchet.length + 32, raw.first == 1 else { throw .badMessage("выгрузка ключа") }
        try self.init(raw: raw, version: 1, verified: false)
    }

    private init(raw: Data, version: UInt8, verified: Bool) throws(CryptoError) {
        let raw = Data(raw)
        let counter = raw[1..<5].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        initialRatchet = try MegolmRatchet(data: raw[5..<(5 + MegolmRatchet.length)], counter: counter)
        signingKey = Data(raw[(5 + MegolmRatchet.length)..<(5 + MegolmRatchet.length + 32)])
        isVerified = verified
    }

    public init(initialRatchet: MegolmRatchet, signingKey: Data, isVerified: Bool) {
        self.initialRatchet = initialRatchet
        self.signingKey = signingKey
        self.isVerified = isVerified
    }

    /// Выгрузка начиная с индекса `index` (для пересылки ключа и бэкапа).
    public func export(at index: UInt32? = nil) throws(CryptoError) -> String {
        var ratchet = initialRatchet
        if let index {
            guard index >= ratchet.counter else { throw .unknownMessageIndex }
            ratchet.advance(to: index)
        }
        var out = Data([1])
        out.append(contentsOf: withUnsafeBytes(of: ratchet.counter.bigEndian, Array.init))
        out.append(ratchet.data)
        out.append(signingKey)
        return Base64.encodeUnpadded(out)
    }

    /// Расшифровка `ciphertext` события `m.room.encrypted`. Возвращает открытый текст и индекс сообщения
    /// (индекс нужен для защиты от повтора: одна пара сессия+индекс не должна встречаться у двух разных событий).
    public func decrypt(_ ciphertext: String) throws(CryptoError) -> (plaintext: Data, messageIndex: UInt32) {
        let parsed = try MegolmMessage.parse(try Base64.decode(ciphertext))
        let signed = parsed.body + parsed.mac
        guard Ed25519KeyPair.verify(signature: parsed.signature, message: signed, publicKey: signingKey) else {
            throw .badSignature
        }
        let index = parsed.message.messageIndex
        guard index >= initialRatchet.counter else { throw .unknownMessageIndex }
        var ratchet = initialRatchet
        ratchet.advance(to: index)
        let keys = ratchet.messageKeys()
        let mac = Hash.hmacSHA256(key: keys.mac, data: parsed.body).prefix(MegolmMessage.macLength)
        guard Data(mac).constantTimeEquals(Data(parsed.mac)) else { throw .badMAC }
        let plaintext = try AES.cbcDecrypt(key: keys.aes, iv: keys.iv, ciphertext: parsed.message.ciphertext)
        return (plaintext, index)
    }
}

/// Минимальный protobuf: только varint и length-delimited, как в форматах Olm/Megolm.
enum Protobuf {
    enum Value {
        case varint(UInt64)
        case bytes(Data)
    }

    static func appendVarint(_ value: UInt64, to out: inout Data) {
        var v = value
        while v >= 0x80 {
            out.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        out.append(UInt8(v))
    }

    struct Reader {
        private let data: Data
        private var position: Int

        init(_ data: Data) {
            self.data = Data(data)
            position = 0
        }

        mutating func varint() throws(CryptoError) -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard position < data.count, shift < 64 else { throw .badMessage("varint") }
                let byte = data[position]
                position += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
        }

        /// Следующее поле (номер, значение) или nil в конце. Поля неизвестных типов — ошибка.
        mutating func next() throws(CryptoError) -> (Int, Value)? {
            guard position < data.count else { return nil }
            let key = try varint()
            let field = Int(key >> 3)
            switch key & 7 {
            case 0:
                return (field, .varint(try varint()))
            case 2:
                let length = Int(try varint())
                guard length >= 0, position + length <= data.count else { throw .badMessage("длина поля") }
                defer { position += length }
                return (field, .bytes(data[position..<position + length]))
            default:
                throw .badMessage("тип поля")
            }
        }
    }
}
