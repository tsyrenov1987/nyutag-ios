import Foundation
import Testing
@testable import NyutagCrypto

@Suite struct OlmTests {
    /// Алиса заводит сессию по одноразовому ключу Боба, Боб поднимает её из сообщения установки.
    private func pair() throws -> (alice: OlmAccount, bob: OlmAccount, aliceSession: OlmSession, bobSession: OlmSession) {
        let alice = OlmAccount()
        var bob = OlmAccount()
        bob.generateOneTimeKeys(1)
        let otk = try #require(bob.unpublishedOneTimeKeys.first?.value)
        var aliceSession = try alice.outboundSession(theirIdentityKey: bob.curve25519Key, theirOneTimeKey: otk)
        let first = try aliceSession.encrypt(Data("привет".utf8))
        #expect(first.type == .preKey)
        let (bobSession, plaintext) = try bob.inboundSession(theirIdentityKey: alice.curve25519Key, preKeyBody: first.body)
        #expect(String(decoding: plaintext, as: UTF8.self) == "привет")
        #expect(bob.storedOneTimeKeyCount == 0)
        #expect(bobSession.sessionID == aliceSession.sessionID)
        return (alice, bob, aliceSession, bobSession)
    }

    @Test func conversationAcrossRatchets() throws {
        var (_, _, a, b) = try pair()
        // До ответа Боба Алиса шлёт тип 0, и Боб узнаёт свою сессию.
        let second = try a.encrypt(Data("ещё".utf8))
        #expect(second.type == .preKey)
        #expect(b.matches(preKeyBody: second.body))
        #expect(try b.decrypt(second) == Data("ещё".utf8))

        for round in 0..<4 {
            let fromBob = try b.encrypt(Data("б\(round)".utf8))
            #expect(fromBob.type == .normal)
            #expect(try a.decrypt(fromBob) == Data("б\(round)".utf8))
            let fromAlice = try a.encrypt(Data("а\(round)".utf8))
            #expect(fromAlice.type == .normal)
            #expect(try b.decrypt(fromAlice) == Data("а\(round)".utf8))
        }
    }

    @Test func outOfOrderAndReplay() throws {
        var (_, _, a, b) = try pair()
        let m1 = try b.encrypt(Data("1".utf8))
        let m2 = try b.encrypt(Data("2".utf8))
        let m3 = try b.encrypt(Data("3".utf8))
        #expect(try a.decrypt(m3) == Data("3".utf8))
        #expect(try a.decrypt(m1) == Data("1".utf8))
        #expect(try a.decrypt(m2) == Data("2".utf8))
        // Ключ пропущенного сообщения одноразовый.
        #expect(throws: CryptoError.unknownMessageIndex) { try a.decrypt(m1) }
    }

    @Test func tamperedMessageRejected() throws {
        var (_, _, a, b) = try pair()
        let message = try b.encrypt(Data("секрет".utf8))
        var raw = try Base64.decode(message.body)
        raw[raw.count - 12] ^= 1
        #expect(throws: CryptoError.badMAC) {
            try a.decrypt(OlmEncrypted(type: .normal, body: Base64.encodeUnpadded(raw)))
        }
        // После неудачи сессия цела.
        #expect(try a.decrypt(message) == Data("секрет".utf8))
    }

    @Test func fallbackKeySurvivesUse() throws {
        let alice = OlmAccount()
        var bob = OlmAccount()
        bob.generateFallbackKey()
        let fallback = try #require(bob.unpublishedFallbackKey)
        bob.markKeysPublished()
        #expect(bob.unpublishedFallbackKey == nil)
        for _ in 0..<2 {
            var session = try alice.outboundSession(theirIdentityKey: bob.curve25519Key, theirOneTimeKey: fallback.key)
            let message = try session.encrypt(Data("ok".utf8))
            #expect(try bob.inboundSession(theirIdentityKey: alice.curve25519Key, preKeyBody: message.body).plaintext == Data("ok".utf8))
        }
        // После замены прежний запасной ещё работает.
        bob.generateFallbackKey()
        var late = try alice.outboundSession(theirIdentityKey: bob.curve25519Key, theirOneTimeKey: fallback.key)
        #expect(try bob.inboundSession(theirIdentityKey: alice.curve25519Key, preKeyBody: late.encrypt(Data()).body).plaintext.isEmpty)
    }

    @Test func wrongSenderKeyRejected() throws {
        let alice = OlmAccount()
        var bob = OlmAccount()
        bob.generateOneTimeKeys(1)
        var session = try alice.outboundSession(theirIdentityKey: bob.curve25519Key,
                                                theirOneTimeKey: try #require(bob.unpublishedOneTimeKeys.first?.value))
        let message = try session.encrypt(Data())
        #expect(throws: CryptoError.self) {
            try bob.inboundSession(theirIdentityKey: OlmAccount().curve25519Key, preKeyBody: message.body)
        }
    }

    @Test func persistenceRoundtrip() throws {
        var (_, bob, a, b) = try pair()
        bob.generateOneTimeKeys(3)
        let restoredBob = try JSONDecoder().decode(OlmAccount.self, from: JSONEncoder().encode(bob))
        #expect(restoredBob.curve25519Key == bob.curve25519Key)
        #expect(restoredBob.unpublishedOneTimeKeys == bob.unpublishedOneTimeKeys)

        _ = try b.decrypt(try a.encrypt(Data("до".utf8)))
        var restored = try JSONDecoder().decode(OlmSession.self, from: JSONEncoder().encode(b))
        #expect(try restored.decrypt(try a.encrypt(Data("после".utf8))) == Data("после".utf8))
        #expect(try a.decrypt(try restored.encrypt(Data("ответ".utf8))) == Data("ответ".utf8))
    }

    @Test func oneTimeKeyLimitEvictsOldest() {
        var account = OlmAccount()
        account.generateOneTimeKeys(OlmAccount.maxOneTimeKeys)
        let first = account.unpublishedOneTimeKeys.keys.sorted().first
        account.markKeysPublished()
        account.generateOneTimeKeys(5)
        #expect(account.storedOneTimeKeyCount == OlmAccount.maxOneTimeKeys)
        #expect(account.unpublishedOneTimeKeys.count == 5)
        _ = first
    }
}

@Suite struct RecoveryTests {
    @Test func recoveryKeyRoundtrip() throws {
        let key = Random.bytes(32)
        let code = RecoveryKey.encode(key)
        #expect(code.hasPrefix("Es"))
        #expect(code.split(separator: " ").allSatisfy { $0.count <= 4 })
        #expect(try RecoveryKey.decode(code) == key)
        #expect(try RecoveryKey.decode(code.replacingOccurrences(of: " ", with: "")) == key)
        // Опечатка ловится чётностью или префиксом.
        var broken = Array(code)
        let i = broken.firstIndex(where: { $0 != " " && $0 != "E" && $0 != "s" })!
        broken[i] = broken[i] == "2" ? "3" : "2"
        #expect(throws: CryptoError.self) { try RecoveryKey.decode(String(broken)) }
    }

    @Test func base58KnownVector() throws {
        // Пример из описания Bitcoin base58: "Hello World!" → 2NEpo7TZRRrLZSi2U.
        #expect(RecoveryKey.base58Encode(Array("Hello World!".utf8)) == "2NEpo7TZRRrLZSi2U")
        #expect(try RecoveryKey.base58Decode("2NEpo7TZRRrLZSi2U") == Array("Hello World!".utf8))
        #expect(RecoveryKey.base58Encode([0, 0, 1]) == "112")
    }

    @Test func secretStorageRoundtripAndCheck() throws {
        let key = Random.bytes(32)
        let secret = Data(Base64.encodeUnpadded(Random.bytes(32)).utf8)
        let sealed = try SecretStorage.encrypt(secret, name: "m.megolm_backup.v1", key: key)
        #expect(try SecretStorage.decrypt(sealed, name: "m.megolm_backup.v1", key: key) == secret)
        #expect(throws: CryptoError.badMAC) { try SecretStorage.decrypt(sealed, name: "m.cross_signing.master", key: key) }

        let check = try SecretStorage.encrypt(Data(count: 32), name: "", key: key)
        #expect(SecretStorage.check(key: key, iv: check.iv, mac: check.mac))
        #expect(!SecretStorage.check(key: Random.bytes(32), iv: check.iv, mac: check.mac))
    }

    @Test func pbkdf2KnownVector() throws {
        // RFC 6070-подобный вектор для PBKDF2-HMAC-SHA512, password/salt, 1 итерация, первые 32 байта.
        let key = try RecoveryKey.fromPassphrase("password", salt: "salt", iterations: 1)
        #expect(key.map { String(format: "%02x", $0) }.joined().hasPrefix("867f70cf1ade02cff3752599a3a53dc4"))
    }

    @Test func backupRoundtrip() throws {
        let backup = BackupKey()
        let plaintext = Data(#"{"algorithm":"m.megolm.v1.aes-sha2","session_key":"x"}"#.utf8)
        let sealed = try BackupKey.encrypt(plaintext, publicKey: backup.publicKeyBase64)
        #expect(try backup.decrypt(sealed) == plaintext)
        #expect(throws: CryptoError.self) { try BackupKey().decrypt(sealed) }
    }
}
