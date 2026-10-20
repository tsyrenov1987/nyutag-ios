// Нютаг. Примитивы для Olm/Megolm из системных фреймворков: CryptoKit (Curve25519, Ed25519, SHA-256, HMAC, HKDF)
// и CommonCrypto (AES-256-CBC, AES-256-CTR). Ничего стороннего.

import CommonCrypto
import CryptoKit
import Foundation

public enum CryptoError: Error, Sendable, Equatable {
    case badKeyLength
    case badBase64
    case badPadding
    case cipherFailed(Int32)
    case badSignature
    case badMessage(String)
    case badMAC
    /// Сообщение раньше первого известного индекса сессии Megolm.
    case unknownMessageIndex
}

// MARK: - Base64 без набивки (как в libolm)

public enum Base64 {
    /// Кодирование без `=` в конце: так записываются ключи и сообщения Olm/Megolm.
    public static func encodeUnpadded(_ data: Data) -> String {
        var string = data.base64EncodedString()
        while string.hasSuffix("=") { string.removeLast() }
        return string
    }

    /// Декодирование строки с набивкой или без неё.
    public static func decode(_ string: String) throws(CryptoError) -> Data {
        var padded = string
        let remainder = padded.count % 4
        if remainder == 2 { padded += "==" } else if remainder == 3 { padded += "=" } else if remainder == 1 { throw .badBase64 }
        guard let data = Data(base64Encoded: padded) else { throw .badBase64 }
        return data
    }
}

// MARK: - Хэши

public enum Hash {
    public static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    public static func hmacSHA256(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    /// HKDF-SHA256: `salt` может быть пустой (тогда по RFC 5869 это 32 нулевых байта).
    public static func hkdfSHA256(ikm: Data, salt: Data, info: Data, outputByteCount: Int) -> Data {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt, info: info, outputByteCount: outputByteCount)
        return key.withUnsafeBytes { Data($0) }
    }
}

// MARK: - Эллиптические кривые

public struct Curve25519KeyPair: Sendable {
    public let privateKey: Curve25519.KeyAgreement.PrivateKey

    public init() { privateKey = Curve25519.KeyAgreement.PrivateKey() }

    public init(rawRepresentation: Data) throws(CryptoError) {
        do {
            privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: rawRepresentation)
        } catch {
            throw .badKeyLength
        }
    }

    public var publicKey: Data { privateKey.publicKey.rawRepresentation }
    public var publicKeyBase64: String { Base64.encodeUnpadded(publicKey) }
    public var rawRepresentation: Data { privateKey.rawRepresentation }

    /// X25519: общий секрет с чужим открытым ключом (32 байта).
    public func sharedSecret(with publicKey: Data) throws(CryptoError) -> Data {
        do {
            let other = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
            let secret = try privateKey.sharedSecretFromKeyAgreement(with: other)
            return secret.withUnsafeBytes { Data($0) }
        } catch {
            throw .badKeyLength
        }
    }
}

public struct Ed25519KeyPair: Sendable {
    public let privateKey: Curve25519.Signing.PrivateKey

    public init() { privateKey = Curve25519.Signing.PrivateKey() }

    public init(rawRepresentation: Data) throws(CryptoError) {
        do {
            privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: rawRepresentation)
        } catch {
            throw .badKeyLength
        }
    }

    public var publicKey: Data { privateKey.publicKey.rawRepresentation }
    public var publicKeyBase64: String { Base64.encodeUnpadded(publicKey) }
    public var rawRepresentation: Data { privateKey.rawRepresentation }

    public func sign(_ message: Data) -> Data {
        // Ed25519 детерминирован, `try` здесь не падает для корректного ключа.
        (try? privateKey.signature(for: message)) ?? Data()
    }

    public static func verify(signature: Data, message: Data, publicKey: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return key.isValidSignature(signature, for: message)
    }
}

// MARK: - AES

public enum AES {
    /// AES-256-CBC с набивкой PKCS#7 (Olm, Megolm, бэкап ключей).
    public static func cbcEncrypt(key: Data, iv: Data, plaintext: Data) throws(CryptoError) -> Data {
        try cbc(CCOperation(kCCEncrypt), key: key, iv: iv, input: plaintext)
    }

    public static func cbcDecrypt(key: Data, iv: Data, ciphertext: Data) throws(CryptoError) -> Data {
        try cbc(CCOperation(kCCDecrypt), key: key, iv: iv, input: ciphertext)
    }

    private static func cbc(_ operation: CCOperation, key: Data, iv: Data, input: Data) throws(CryptoError) -> Data {
        guard key.count == kCCKeySizeAES256, iv.count == kCCBlockSizeAES128 else { throw .badKeyLength }
        var output = Data(count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let status = output.withUnsafeMutableBytes { outBytes in
            input.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                inBytes.baseAddress, input.count,
                                outBytes.baseAddress, outBytes.count, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw status == kCCDecodeError ? .badPadding : .cipherFailed(status)
        }
        output.removeSubrange(moved...)
        return output
    }

    /// AES-256-CTR без набивки (SSSS, `m.secret_storage.v1.aes-hmac-sha2`).
    public static func ctr(key: Data, iv: Data, input: Data) throws(CryptoError) -> Data {
        guard key.count == kCCKeySizeAES256, iv.count == kCCBlockSizeAES128 else { throw .badKeyLength }
        var cryptor: CCCryptorRef?
        let create = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                                        CCPadding(ccNoPadding), ivBytes.baseAddress, keyBytes.baseAddress, key.count,
                                        nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
            }
        }
        guard create == kCCSuccess, let cryptor else { throw .cipherFailed(create) }
        defer { CCCryptorRelease(cryptor) }
        var output = Data(count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let update = output.withUnsafeMutableBytes { outBytes in
            input.withUnsafeBytes { inBytes in
                CCCryptorUpdate(cryptor, inBytes.baseAddress, input.count, outBytes.baseAddress, outBytes.count, &moved)
            }
        }
        guard update == kCCSuccess else { throw .cipherFailed(update) }
        output.removeSubrange(moved...)
        return output
    }
}

// MARK: - Случайные байты

public enum Random {
    public static func bytes(_ count: Int) -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return data
    }
}

extension Data {
    /// Сравнение за постоянное время (теги HMAC).
    public func constantTimeEquals(_ other: Data) -> Bool {
        guard count == other.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(self, other) { diff |= a ^ b }
        return diff == 0
    }
}
