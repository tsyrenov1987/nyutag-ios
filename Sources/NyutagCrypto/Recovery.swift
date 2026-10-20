// Нютаг. Восстановление ключей: recovery-код (base58), хранилище секретов SSSS
// (`m.secret_storage.v1.aes-hmac-sha2`) и бэкап ключей комнат (`m.megolm_backup.v1.curve25519-aes-sha2`).

import CommonCrypto
import Foundation

// MARK: - Recovery-код

public enum RecoveryKey {
    private static let prefix: [UInt8] = [0x8B, 0x01]
    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")

    /// Ключ SSSS (32 байта) из кода вида `EsTx xxxx …`; пробелы не важны.
    public static func decode(_ code: String) throws(CryptoError) -> Data {
        let raw = try base58Decode(code.filter { !$0.isWhitespace })
        guard raw.count == prefix.count + 32 + 1, Array(raw.prefix(2)) == prefix else { throw .badMessage("recovery: формат") }
        guard raw.reduce(0, ^) == 0 else { throw .badMessage("recovery: чётность") }
        return Data(raw[2..<34])
    }

    /// Код для показа человеку: группы по четыре символа.
    public static func encode(_ key: Data) -> String {
        var raw = prefix + Array(key)
        raw.append(raw.reduce(0, ^))
        let text = base58Encode(raw)
        return stride(from: 0, to: text.count, by: 4).map { start in
            let from = text.index(text.startIndex, offsetBy: start)
            return String(text[from..<(text.index(from, offsetBy: 4, limitedBy: text.endIndex) ?? text.endIndex)])
        }.joined(separator: " ")
    }

    static func base58Decode(_ text: String) throws(CryptoError) -> [UInt8] {
        var bytes: [UInt8] = []  // младшие байты в конце
        for char in text {
            guard let digit = alphabet.firstIndex(of: char) else { throw .badMessage("recovery: символ") }
            var carry = digit
            for i in stride(from: bytes.count - 1, through: 0, by: -1) {
                carry += Int(bytes[i]) * 58
                bytes[i] = UInt8(carry & 0xFF)
                carry >>= 8
            }
            while carry > 0 {
                bytes.insert(UInt8(carry & 0xFF), at: 0)
                carry >>= 8
            }
        }
        let zeros = text.prefix { $0 == "1" }.count
        return Array(repeating: 0, count: zeros) + bytes
    }

    static func base58Encode(_ bytes: [UInt8]) -> String {
        var digits: [Int] = []  // младшие цифры в конце
        for byte in bytes {
            var carry = Int(byte)
            for i in stride(from: digits.count - 1, through: 0, by: -1) {
                carry += digits[i] << 8
                digits[i] = carry % 58
                carry /= 58
            }
            while carry > 0 {
                digits.insert(carry % 58, at: 0)
                carry /= 58
            }
        }
        let zeros = bytes.prefix { $0 == 0 }.count
        return String(repeating: "1", count: zeros) + String(digits.map { alphabet[$0] })
    }

    /// Ключ из парольной фразы: PBKDF2-SHA-512 (`m.pbkdf2` в описании ключа SSSS).
    public static func fromPassphrase(_ passphrase: String, salt: String, iterations: Int,
                                      bits: Int = 256) throws(CryptoError) -> Data {
        var key = Data(count: bits / 8)
        let password = Array(passphrase.utf8)
        let saltBytes = Array(salt.utf8)
        let status = key.withUnsafeMutableBytes { out in
            password.withUnsafeBufferPointer { pw in
                pw.withMemoryRebound(to: CChar.self) { pwChars in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pwChars.baseAddress, password.count,
                                         saltBytes, saltBytes.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
                                         UInt32(iterations), out.bindMemory(to: UInt8.self).baseAddress, bits / 8)
                }
            }
        }
        guard status == kCCSuccess else { throw .cipherFailed(status) }
        return key
    }
}

// MARK: - SSSS

/// Зашифрованный секрет или проверочная запись ключа: `{iv, ciphertext, mac}` в base64.
public struct SecretStorageCiphertext: Sendable, Equatable {
    public let iv: String
    public let ciphertext: String
    public let mac: String

    public init(iv: String, ciphertext: String, mac: String) {
        self.iv = iv
        self.ciphertext = ciphertext
        self.mac = mac
    }
}

public enum SecretStorage {
    /// Шифрование секрета `name` ключом SSSS. Открытый текст — сам секрет (у ключей это base64 строкой).
    public static func encrypt(_ plaintext: Data, name: String, key: Data,
                               iv: Data? = nil) throws(CryptoError) -> SecretStorageCiphertext {
        var iv = iv ?? Random.bytes(16)
        iv[iv.startIndex + 8] &= 0x7F  // по спецификации: бит 63 сброшен, чтобы счётчик CTR не переполнился
        let keys = derive(key: key, name: name)
        let ciphertext = try AES.ctr(key: keys.aes, iv: iv, input: plaintext)
        let mac = Hash.hmacSHA256(key: keys.mac, data: ciphertext)
        return SecretStorageCiphertext(iv: ciphertext64(iv), ciphertext: ciphertext64(ciphertext), mac: ciphertext64(mac))
    }

    public static func decrypt(_ encrypted: SecretStorageCiphertext, name: String, key: Data) throws(CryptoError) -> Data {
        let keys = derive(key: key, name: name)
        let ciphertext = try Base64.decode(encrypted.ciphertext)
        let mac = Hash.hmacSHA256(key: keys.mac, data: ciphertext)
        guard mac.constantTimeEquals(try Base64.decode(encrypted.mac)) else { throw .badMAC }
        return try AES.ctr(key: keys.aes, iv: try Base64.decode(encrypted.iv), input: ciphertext)
    }

    /// Подходит ли ключ к описанию `m.secret_storage.key.<id>`: шифруем 32 нуля с пустым именем и тем же iv.
    public static func check(key: Data, iv: String, mac: String) -> Bool {
        guard let ivData = try? Base64.decode(iv),
              let expected = try? encrypt(Data(count: 32), name: "", key: key, iv: ivData),
              let ours = try? Base64.decode(expected.mac), let theirs = try? Base64.decode(mac) else { return false }
        return ours.constantTimeEquals(theirs)
    }

    private static func derive(key: Data, name: String) -> (aes: Data, mac: Data) {
        let out = Hash.hkdfSHA256(ikm: key, salt: Data(count: 32), info: Data(name.utf8), outputByteCount: 64)
        return (out.prefix(32), out.suffix(32))
    }

    /// Element и спецификация пишут SSSS обычным base64 с набивкой; читаем любой.
    private static func ciphertext64(_ data: Data) -> String { data.base64EncodedString() }
}

// MARK: - Бэкап ключей комнат

/// Зашифрованная запись бэкапа (`session_data`).
public struct BackupSessionData: Sendable, Equatable {
    public let ephemeral: String
    public let ciphertext: String
    public let mac: String

    public init(ephemeral: String, ciphertext: String, mac: String) {
        self.ephemeral = ephemeral
        self.ciphertext = ciphertext
        self.mac = mac
    }
}

/// Ключ бэкапа `m.megolm_backup.v1.curve25519-aes-sha2`: Curve25519, открытая часть лежит в версии бэкапа на сервере.
public struct BackupKey: Sendable {
    public let keyPair: Curve25519KeyPair

    public init(privateKey: Data) throws(CryptoError) { keyPair = try Curve25519KeyPair(rawRepresentation: privateKey) }
    public init() { keyPair = Curve25519KeyPair() }

    public var publicKeyBase64: String { keyPair.publicKeyBase64 }

    /// Расшифровка записи. libolm (а за ним и все клиенты) считает MAC от пустой строки, а не от шифртекста;
    /// принимаем оба варианта.
    public func decrypt(_ data: BackupSessionData) throws(CryptoError) -> Data {
        let ciphertext = try Base64.decode(data.ciphertext)
        let keys = Self.derive(try keyPair.sharedSecret(with: try Base64.decode(data.ephemeral)))
        let mac = try Base64.decode(data.mac)
        let legacy = Hash.hmacSHA256(key: keys.mac, data: Data()).prefix(8)
        let proper = Hash.hmacSHA256(key: keys.mac, data: ciphertext).prefix(8)
        guard Data(legacy).constantTimeEquals(mac) || Data(proper).constantTimeEquals(mac) else { throw .badMAC }
        return try AES.cbcDecrypt(key: keys.aes, iv: keys.iv, ciphertext: ciphertext)
    }

    /// Шифрование записи под открытый ключ бэкапа (MAC как у libolm, чтобы читали все клиенты).
    public static func encrypt(_ plaintext: Data, publicKey: String) throws(CryptoError) -> BackupSessionData {
        let ephemeral = Curve25519KeyPair()
        let keys = derive(try ephemeral.sharedSecret(with: try Base64.decode(publicKey)))
        let ciphertext = try AES.cbcEncrypt(key: keys.aes, iv: keys.iv, plaintext: plaintext)
        let mac = Hash.hmacSHA256(key: keys.mac, data: Data()).prefix(8)
        return BackupSessionData(ephemeral: ephemeral.publicKeyBase64, ciphertext: Base64.encodeUnpadded(ciphertext),
                                 mac: Base64.encodeUnpadded(Data(mac)))
    }

    private static func derive(_ secret: Data) -> (aes: Data, mac: Data, iv: Data) {
        let out = Hash.hkdfSHA256(ikm: secret, salt: Data(count: 32), info: Data(), outputByteCount: 80)
        let base = out.startIndex
        return (out[base..<base + 32], out[base + 32..<base + 64], out[base + 64..<base + 80])
    }
}
