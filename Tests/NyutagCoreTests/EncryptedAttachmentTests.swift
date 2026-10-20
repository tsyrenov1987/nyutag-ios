import Foundation
@testable import NyutagCore
import NyutagCrypto
import Testing

struct EncryptedAttachmentTests {
    private let sample = Data((0..<1000).map { UInt8($0 % 251) })

    private func sealed() throws -> (Data, EncryptedFile) {
        try EncryptedFile.encrypt(sample, url: "mxc://x/y")
    }

    @Test func roundTrip() throws {
        let (cipher, file) = try sealed()
        #expect(cipher != sample && cipher.count == sample.count)
        #expect(try file.decrypt(cipher) == sample)
        let empty = try EncryptedFile.encrypt(Data())
        #expect(try empty.file.decrypt(empty.ciphertext) == Data())
    }

    @Test func freshKeyAndIVEachTime() throws {
        let a = try sealed().1, b = try sealed().1
        #expect(a.key.k != b.key.k)
        #expect(a.iv != b.iv)
    }

    @Test func rejectsTamperedHash() throws {
        let (cipher, original) = try sealed()
        var file = original
        file.hashes["sha256"] = Base64.encodeUnpadded(Data(repeating: 0, count: 32))
        #expect(throws: CryptoError.badMAC) { try file.decrypt(cipher) }
        file.hashes = [:]
        #expect(throws: CryptoError.self) { try file.decrypt(cipher) }
    }

    @Test func rejectsTamperedByte() throws {
        var (cipher, file) = try sealed()
        cipher[500] ^= 1
        #expect(throws: CryptoError.badMAC) { try file.decrypt(cipher) }
        file.v = "v2"
    }

    @Test func rejectsWrongVersionAndAlg() throws {
        let (cipher, file) = try sealed()
        var v1 = file; v1.v = "v1"
        #expect(throws: CryptoError.self) { try v1.decrypt(cipher) }
        var alg = file; alg.key.alg = "A128CTR"
        #expect(throws: CryptoError.self) { try alg.decrypt(cipher) }
        var kty = file; kty.key.kty = "RSA"
        #expect(throws: CryptoError.self) { try kty.decrypt(cipher) }
    }

    @Test func jsonFormat() throws {
        let (_, file) = try sealed()
        let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(file))
        #expect(Set(json.object!.keys) == ["url", "key", "iv", "hashes", "v"])
        #expect(json["v"]?.string == "v2")
        #expect(json["url"]?.string == "mxc://x/y")
        let key = try #require(json["key"])
        #expect(Set(key.object!.keys) == ["kty", "key_ops", "alg", "k", "ext"])
        #expect(key["kty"]?.string == "oct")
        #expect(key["alg"]?.string == "A256CTR")
        #expect(key["ext"]?.bool == true)
        #expect(key["key_ops"]?.array?.compactMap(\.string) == ["encrypt", "decrypt"])
        // k: base64url без набивки, 32 байта = 43 символа, без «+», «/», «=».
        let k = try #require(key["k"]?.string)
        #expect(k.count == 43)
        #expect(!k.contains(where: { "+/=".contains($0) }))
        #expect(try EncryptedFile.decodeBase64URL(k).count == 32)
        // iv: 16 байт, без набивки, последние 8 нулевые.
        let iv = try #require(json["iv"]?.string)
        #expect(!iv.contains("="))
        let ivBytes = try Base64.decode(iv)
        #expect(ivBytes.count == 16)
        #expect(ivBytes.suffix(8) == Data(count: 8))
        let hash = try #require(json["hashes"]?["sha256"]?.string)
        #expect(!hash.contains("="))
        #expect(try Base64.decode(hash).count == 32)
    }

    @Test func base64URLUsesUrlAlphabet() throws {
        let data = Data([0xfb, 0xff, 0xfe, 0xfa, 0xff])   // стандартный base64 даёт «+» и «/»
        let s = EncryptedFile.base64URL(data)
        #expect(!s.contains("+") && !s.contains("/"))
        #expect(s.contains("-") || s.contains("_"))
        #expect(try EncryptedFile.decodeBase64URL(s) == data)
    }

    /// Вектор NIST SP 800-38A, F.5.5 (CTR-AES256.Encrypt, первый блок): проверяет, что iv идёт в CTR как
    /// начальный 16-байтный счётчик (big-endian). Готового достоверного вектора именно EncryptedFile v2
    /// не взято (спека описывает формат, а не байты) — не выдумываю.
    @Test func nistCTRVector() throws {
        func hex(_ s: String) -> Data {
            let chars = Array(s)
            return Data(stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...$0 + 1]), radix: 16)! })
        }
        let key = hex("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4")
        let iv = hex("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")
        let plain = hex("6bc1bee22e409f96e93d7e117393172a")
        let expected = hex("601ec313775789a5b7a7f504bbf3d228")
        let (cipher, file) = try EncryptedFile.encrypt(plain, key: key, iv: iv, url: "mxc://x/y")
        #expect(cipher == expected)
        #expect(try file.decrypt(cipher) == plain)
    }

    @Test func contentUsesFileInsteadOfURL() throws {
        let (_, file) = try sealed()
        let (_, thumb) = try EncryptedFile.encrypt(Data([1, 2, 3]), url: "mxc://x/t")
        let content = try file.content(msgtype: "m.image", body: "cat.png",
                                       info: ["mimetype": .string("image/png"), "thumbnail_url": .string("mxc://leak/1")],
                                       thumbnail: thumb)
        #expect(content["msgtype"]?.string == "m.image")
        #expect(content["url"] == nil)
        #expect(content["file"]?["url"]?.string == "mxc://x/y")
        #expect(content["info"]?["mimetype"]?.string == "image/png")
        #expect(content["info"]?["thumbnail_url"] == nil)
        #expect(content["info"]?["thumbnail_file"]?["url"]?.string == "mxc://x/t")
        let decoded = try JSONDecoder().decode(EncryptedFile.self, from: JSONEncoder().encode(try #require(content["file"])))
        #expect(decoded == file)
    }
}
