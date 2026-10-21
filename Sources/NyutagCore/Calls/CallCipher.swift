// Нютаг. Ключи звонка и шифр кадров.
// Каждая сторона на звонок заводит одноразовую пару X25519 и отдаёт открытый ключ в offer/answer. Из общего
// секрета HKDF-SHA256 выводит два ключа ChaChaPoly (по одному на направление) и «слот» релея: релей сводит
// участников по слоту и не знает ни комнаты, ни ключа.
//
// Кадр: [вид 1 байт][номер 4 байта BE][шифртекст][метка 16 байт]. Одноразовое число — номер кадра, дополненный
// нулями, а для видео и служебных — с видом в первом байте: ключи у направлений разные, у каждого вида свой счёт,
// поэтому оно не повторяется. Заголовок входит в проверку подлинности.

import CryptoKit
import Foundation

public struct CallKeyPair: Sendable {
    let privateKey: Curve25519.KeyAgreement.PrivateKey

    public init() { privateKey = Curve25519.KeyAgreement.PrivateKey() }

    public var publicKey: Data { privateKey.publicKey.rawRepresentation }

    /// Ключи звонка. `isCaller` — мы звоним: наш ключ отправки первый в выводе.
    public func secret(with theirs: Data, callID: String, isCaller: Bool) throws -> CallSecret {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirs)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        let material = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(callID.utf8),
                                                      sharedInfo: Data("nyutag call v1".utf8), outputByteCount: 80)
        let bytes = material.withUnsafeBytes { Data($0) }
        let callerKey = SymmetricKey(data: bytes[0..<32])
        let calleeKey = SymmetricKey(data: bytes[32..<64])
        let slot = bytes[64..<80].map { String(format: "%02x", $0) }.joined()
        return CallSecret(slot: slot, sendKey: isCaller ? callerKey : calleeKey, receiveKey: isCaller ? calleeKey : callerKey)
    }
}

public struct CallSecret: Sendable {
    /// 32 hex-символа: адрес встречи на релее.
    public let slot: String
    let sendKey: SymmetricKey
    let receiveKey: SymmetricKey
}

public enum FrameKind: UInt8, Sendable {
    case audio = 1
    case video = 2
    /// Служебное внутри звонка: просьба о ключевом кадре, камера выключена.
    case control = 3
}

/// Запечатывает исходящие кадры и открывает входящие. Номер исходящих растёт сам: один шифр — один вид кадров.
public struct CallCipher: Sendable {
    static let headerSize = 5
    private let secret: CallSecret
    private var nextSequence: UInt32 = 0

    public init(_ secret: CallSecret) { self.secret = secret }

    public mutating func seal(_ kind: FrameKind, _ payload: Data) -> Data? {
        let sequence = nextSequence
        nextSequence &+= 1
        var header = Data([kind.rawValue])
        withUnsafeBytes(of: sequence.bigEndian) { header.append(contentsOf: $0) }
        guard let box = try? ChaChaPoly.seal(payload, using: secret.sendKey, nonce: Self.nonce(kind, sequence),
                                             authenticating: header) else { return nil }
        return header + box.ciphertext + box.tag
    }

    /// `nil` — кадр подделан, повреждён или не от собеседника.
    public func open(_ packet: Data) -> (kind: FrameKind, sequence: UInt32, payload: Data)? {
        guard packet.count >= Self.headerSize + 16 else { return nil }
        let bytes = [UInt8](packet)
        guard let kind = FrameKind(rawValue: bytes[0]) else { return nil }
        let sequence = bytes[1..<5].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let header = Data(bytes[0..<5])
        let ciphertext = Data(bytes[5..<(bytes.count - 16)])
        let tag = Data(bytes[(bytes.count - 16)...])
        guard let box = try? ChaChaPoly.SealedBox(nonce: Self.nonce(kind, sequence), ciphertext: ciphertext, tag: tag),
              let payload = try? ChaChaPoly.open(box, using: secret.receiveKey, authenticating: header) else { return nil }
        return (kind, sequence, payload)
    }

    private static func nonce(_ kind: FrameKind, _ sequence: UInt32) -> ChaChaPoly.Nonce {
        var bytes = [UInt8](repeating: 0, count: 12)
        // Голос — с нулём, как в первой версии кадра.
        if kind != .audio { bytes[0] = kind.rawValue }
        withUnsafeBytes(of: sequence.bigEndian) { for (i, b) in $0.enumerated() { bytes[8 + i] = b } }
        // 12 байт — ровно размер одноразового числа ChaChaPoly, конструктор не откажет.
        return try! ChaChaPoly.Nonce(data: bytes)
    }
}
