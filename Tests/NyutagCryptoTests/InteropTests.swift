// Совместимость с эталонной реализацией Olm/Megolm (vodozemac, на ней Element и Android-клиенты).
// Fixtures/interop.json сгенерирован один раз её Python-обвязкой вне репозитория; в приложение она не входит.
// Раздел `reverse` — обратное направление: наши сообщения эталон расшифровал и ответил, мы читаем ответы.
// Перегенерация: NYUTAG_INTEROP_OUT=путь swift test --filter emitOurSide, затем скрипт эталона дописывает `reverse`.

import Foundation
import Testing
@testable import NyutagCrypto

@Suite struct InteropTests {
    nonisolated(unsafe) private static let fixture: [String: Any] = {
        let url = Bundle.module.url(forResource: "interop", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }()

    private func section(_ name: String) throws -> [String: Any] {
        try #require(Self.fixture[name] as? [String: Any])
    }

    private func list(_ dict: [String: Any], _ key: String) throws -> [[String: Any]] {
        try #require(dict[key] as? [[String: Any]])
    }

    @Test func megolmFromReference() throws {
        let megolm = try section("megolm")
        let session = try MegolmInboundSession(sessionKey: megolm["session_key"] as! String)
        #expect(session.sessionID == megolm["session_id"] as? String)
        let messages = try list(megolm, "messages")
        for message in messages {
            let result = try session.decrypt(message["ciphertext"] as! String)
            #expect(String(decoding: result.plaintext, as: UTF8.self) == message["plaintext"] as? String)
            #expect(Int(result.messageIndex) == message["index"] as? Int)
        }
        // Экспорт с индекса 2 читает 2…4 и не читает 0.
        let exported = try MegolmInboundSession(exportedKey: megolm["export_at_2"] as! String)
        #expect(exported.firstKnownIndex == 2)
        #expect(try exported.decrypt(messages[3]["ciphertext"] as! String).messageIndex == 3)
        #expect(throws: CryptoError.unknownMessageIndex) { try exported.decrypt(messages[0]["ciphertext"] as! String) }
    }

    @Test func olmFromReference() throws {
        let olm = try section("olm")
        let accountJSON = try JSONSerialization.data(withJSONObject: try #require(olm["account"]))
        var account = try JSONDecoder().decode(OlmAccount.self, from: accountJSON)
        let sender = olm["sender_key"] as! String
        let messages = try list(olm, "messages")
        #expect(messages.allSatisfy { $0["type"] as? Int == 0 })
        var (session, first) = try account.inboundSession(theirIdentityKey: sender, preKeyBody: messages[0]["body"] as! String)
        #expect(String(decoding: first, as: UTF8.self) == messages[0]["plaintext"] as? String)
        #expect(account.storedOneTimeKeyCount == 0)
        for message in messages.dropFirst() {
            let body = message["body"] as! String
            #expect(session.matches(preKeyBody: body))
            let plaintext = try session.decrypt(OlmEncrypted(type: .preKey, body: body))
            #expect(String(decoding: plaintext, as: UTF8.self) == message["plaintext"] as? String)
        }
    }

    @Test func backupFromReference() throws {
        let backup = try section("backup")
        let key = try BackupKey(privateKey: try Base64.decode(backup["private_key"] as! String))
        #expect(key.publicKeyBase64 == backup["public_key"] as? String)
        for record in try list(backup, "records") {
            let data = BackupSessionData(ephemeral: record["ephemeral"] as! String, ciphertext: record["ciphertext"] as! String,
                                         mac: record["mac"] as! String)
            #expect(String(decoding: try key.decrypt(data), as: UTF8.self) == record["plaintext"] as? String)
        }
    }

    /// Эталон расшифровал наши Megolm, Olm и запись бэкапа (`verified`) и ответил по Olm с новым храповиком.
    @Test func referenceReadsUsAndReplies() throws {
        let reverse = try section("reverse")
        let verified = try #require(reverse["verified"] as? [String])
        #expect(Set(verified) == ["megolm", "olm", "backup"])
        let stateJSON = try JSONSerialization.data(withJSONObject: try #require(reverse["our_session"]))
        var session = try JSONDecoder().decode(OlmSession.self, from: stateJSON)
        for reply in try list(reverse, "replies") {
            #expect(reply["type"] as? Int == 1)
            let plaintext = try session.decrypt(OlmEncrypted(type: .normal, body: reply["body"] as! String))
            #expect(String(decoding: plaintext, as: UTF8.self) == reply["plaintext"] as? String)
        }
        // После ответа мы шлём обычные сообщения, а не установочные.
        #expect(try session.encrypt(Data("ок".utf8)).type == .normal)
    }

    /// Наша сторона для эталона: пишется только при перегенерации фикстуры.
    /// SAS: эталон знает только наш открытый ключ; эмодзи, числа и MAC должны совпасть у обеих сторон.
    @Test func sasMatchesReference() throws {
        let sas = try section("sas")
        let ours = try Sas(privateKey: try Base64.decode(sas["our_private"] as! String))
        #expect(ours.publicKeyBase64 == sas["our_public"] as? String)
        let established = try ours.establish(theirPublicKey: sas["their_public"] as! String)
        let info = sas["info"] as! String
        #expect(established.emojiIndices(info: info) == sas["emoji_indices"] as? [Int])
        #expect(established.decimals(info: info) == sas["decimals"] as? [Int])
        for mac in try list(sas, "macs") {
            #expect(established.calculateMac(mac["input"] as! String, info: mac["info"] as! String) == mac["mac"] as? String)
        }
        #expect(SasEmoji.table.count == 64)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NYUTAG_INTEROP_OUT"] != nil))
    func emitOurSide() throws {
        let peer = try section("peer")
        let backup = try section("backup")
        let account = OlmAccount()
        var olm = try account.outboundSession(theirIdentityKey: peer["identity"] as! String,
                                              theirOneTimeKey: peer["one_time_key"] as! String)
        let olmText = "сайн, эталон"
        let prekey = try olm.encrypt(Data(olmText.utf8))

        var outbound = MegolmOutboundSession()
        let sessionKey = outbound.sessionKey()
        let texts = (0..<3).map { "мегольм \($0)" }
        let megolm = try texts.map { ["ciphertext": try outbound.encrypt(Data($0.utf8)), "plaintext": $0] }

        let backupText = #"{"algorithm":"m.megolm.v1.aes-sha2","session_key":"наш"}"#
        let record = try BackupKey.encrypt(Data(backupText.utf8), publicKey: backup["public_key"] as! String)

        let out: [String: Any] = [
            "olm": ["sender_key": account.curve25519Key, "type": prekey.type.rawValue, "body": prekey.body,
                    "plaintext": olmText,
                    "our_session": try JSONSerialization.jsonObject(with: JSONEncoder().encode(olm))],
            "megolm": ["session_key": sessionKey, "session_id": outbound.sessionID, "messages": megolm],
            "backup": ["ephemeral": record.ephemeral, "ciphertext": record.ciphertext, "mac": record.mac,
                       "plaintext": backupText],
        ]
        let path = ProcessInfo.processInfo.environment["NYUTAG_INTEROP_OUT"]!
        try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted]).write(to: URL(fileURLWithPath: path))
    }
}
