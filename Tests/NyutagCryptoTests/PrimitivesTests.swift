import Foundation
@testable import NyutagCrypto
import Testing

@Suite struct PrimitivesTests {
    @Test func base64Unpadded() throws {
        let data = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01])
        let encoded = Base64.encodeUnpadded(data)
        #expect(!encoded.hasSuffix("="))
        #expect(try Base64.decode(encoded) == data)
        #expect(try Base64.decode(data.base64EncodedString()) == data)
        #expect(throws: CryptoError.badBase64) { try Base64.decode("A") }
    }

    @Test func sha256AndHMACVectors() {
        // RFC 4231, тест 2.
        let key = Data("Jefe".utf8)
        let message = Data("what do ya want for nothing?".utf8)
        let expected = "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
        #expect(Hash.hmacSHA256(key: key, data: message).map { String(format: "%02x", $0) }.joined() == expected)
        #expect(Hash.sha256(Data("abc".utf8)).map { String(format: "%02x", $0) }.joined()
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func hkdfVector() {
        // RFC 5869, тест 1.
        let ikm = Data(repeating: 0x0B, count: 22)
        let salt = Data((0x00...0x0C).map { UInt8($0) })
        let info = Data((0xF0...0xF9).map { UInt8($0) })
        let okm = Hash.hkdfSHA256(ikm: ikm, salt: salt, info: info, outputByteCount: 42)
        #expect(okm.map { String(format: "%02x", $0) }.joined()
            == "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")
    }

    @Test func x25519AgreementIsSymmetric() throws {
        let alice = Curve25519KeyPair()
        let bob = Curve25519KeyPair()
        let ab = try alice.sharedSecret(with: bob.publicKey)
        let ba = try bob.sharedSecret(with: alice.publicKey)
        #expect(ab == ba)
        #expect(ab.count == 32)
        let restored = try Curve25519KeyPair(rawRepresentation: alice.rawRepresentation)
        #expect(restored.publicKey == alice.publicKey)
        #expect(alice.publicKeyBase64.count == 43)
    }

    @Test func ed25519SignVerify() throws {
        let pair = Ed25519KeyPair()
        let message = Data("{\"a\":1}".utf8)
        let signature = pair.sign(message)
        #expect(signature.count == 64)
        #expect(Ed25519KeyPair.verify(signature: signature, message: message, publicKey: pair.publicKey))
        #expect(!Ed25519KeyPair.verify(signature: signature, message: Data("x".utf8), publicKey: pair.publicKey))
    }

    @Test func aesCBCRoundTripAndPadding() throws {
        let key = Random.bytes(32)
        let iv = Random.bytes(16)
        for length in [0, 1, 15, 16, 17, 100] {
            let plaintext = Random.bytes(length)
            let ciphertext = try AES.cbcEncrypt(key: key, iv: iv, plaintext: plaintext)
            #expect(ciphertext.count == (length / 16 + 1) * 16)
            #expect(try AES.cbcDecrypt(key: key, iv: iv, ciphertext: ciphertext) == plaintext)
        }
        #expect(throws: CryptoError.self) { try AES.cbcEncrypt(key: Data(count: 16), iv: iv, plaintext: Data()) }
    }

    @Test func aesCTRVector() throws {
        // NIST SP 800-38A, F.5.5 CTR-AES256, первый блок.
        let key = Data(hex: "603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4")
        let iv = Data(hex: "f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")
        let plaintext = Data(hex: "6bc1bee22e409f96e93d7e117393172a")
        let ciphertext = try AES.ctr(key: key, iv: iv, input: plaintext)
        #expect(ciphertext == Data(hex: "601ec313775789a5b7a7f504bbf3d228"))
        #expect(try AES.ctr(key: key, iv: iv, input: ciphertext) == plaintext)
    }

    @Test func constantTimeEquals() {
        #expect(Data([1, 2, 3]).constantTimeEquals(Data([1, 2, 3])))
        #expect(!Data([1, 2, 3]).constantTimeEquals(Data([1, 2, 4])))
        #expect(!Data([1, 2, 3]).constantTimeEquals(Data([1, 2])))
    }
}

extension Data {
    init(hex: String) {
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self = data
    }
}
