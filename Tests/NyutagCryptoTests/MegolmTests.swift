import Foundation
@testable import NyutagCrypto
import Testing

struct MegolmTests {
    private func seeded() throws -> MegolmRatchet {
        try MegolmRatchet(data: Data((0..<128).map { UInt8($0) }), counter: 0)
    }

    /// Прыжок `advance(to:)` обязан давать то же, что пошаговый `advance()`, в том числе через границы 2^8 и 2^16.
    @Test(arguments: [1, 2, 255, 256, 257, 511, 1000, 65535, 65536, 65537, 70000])
    func jumpEqualsSteps(target: Int) throws {
        var stepped = try seeded()
        for _ in 0..<target { stepped.advance() }
        var jumped = try seeded()
        jumped.advance(to: UInt32(target))
        #expect(jumped == stepped)
        #expect(jumped.counter == UInt32(target))
    }

    @Test func jumpFromMiddle() throws {
        var a = try seeded()
        a.advance(to: 300)
        a.advance(to: 70_001)
        var b = try seeded()
        b.advance(to: 70_001)
        #expect(a == b)
    }

    @Test func rehashMatchesDefinition() throws {
        // R(1,3) = HMAC(R(0,3), 0x03), остальные части без изменений.
        let start = try seeded()
        var next = start
        next.advance()
        let r3 = Hash.hmacSHA256(key: start.data[96..<128], data: Data([3]))
        #expect(next.data[96..<128] == r3)
        #expect(next.data[0..<96] == start.data[0..<96])
        // На 256-м шаге пересчитываются R2 и R3 от R2.
        var at255 = start
        at255.advance(to: 255)
        var at256 = at255
        at256.advance()
        let r2 = at255.data[64..<96]
        #expect(at256.data[64..<96] == Hash.hmacSHA256(key: Data(r2), data: Data([2])))
        #expect(at256.data[96..<128] == Hash.hmacSHA256(key: Data(r2), data: Data([3])))
    }

    @Test func roundTripThroughSessionKey() throws {
        var outbound = MegolmOutboundSession()
        let first = try outbound.encrypt(Data("до ключа".utf8))
        let key = outbound.sessionKey()
        let inbound = try MegolmInboundSession(sessionKey: key)
        #expect(inbound.sessionID == outbound.sessionID)
        #expect(inbound.firstKnownIndex == 1)
        #expect(inbound.isVerified)
        #expect(throws: CryptoError.unknownMessageIndex) { try inbound.decrypt(first) }

        var messages: [String] = []
        for i in 0..<300 { messages.append(try outbound.encrypt(Data("сообщение \(i)".utf8))) }
        let last = try inbound.decrypt(messages[299])
        #expect(String(decoding: last.plaintext, as: UTF8.self) == "сообщение 299")
        #expect(last.messageIndex == 300)
        let early = try inbound.decrypt(messages[0])
        #expect(String(decoding: early.plaintext, as: UTF8.self) == "сообщение 0")
    }

    @Test func exportFromLaterIndex() throws {
        var outbound = MegolmOutboundSession()
        let inbound = try MegolmInboundSession(sessionKey: outbound.sessionKey())
        var messages: [String] = []
        for i in 0..<10 { messages.append(try outbound.encrypt(Data("№\(i)".utf8))) }
        let forwarded = try MegolmInboundSession(exportedKey: try inbound.export(at: 5))
        #expect(!forwarded.isVerified)
        #expect(forwarded.firstKnownIndex == 5)
        #expect(throws: CryptoError.unknownMessageIndex) { try forwarded.decrypt(messages[4]) }
        #expect(String(decoding: try forwarded.decrypt(messages[7]).plaintext, as: UTF8.self) == "№7")
        // Выгрузка без индекса равна исходному храповику.
        #expect(try MegolmInboundSession(exportedKey: inbound.export()).initialRatchet == inbound.initialRatchet)
    }

    @Test func tamperingIsRejected() throws {
        var outbound = MegolmOutboundSession()
        let inbound = try MegolmInboundSession(sessionKey: outbound.sessionKey())
        var raw = try Base64.decode(try outbound.encrypt(Data("целое".utf8)))
        raw[raw.count - 70] ^= 1 // байт MAC
        #expect(throws: CryptoError.badSignature) { try inbound.decrypt(Base64.encodeUnpadded(raw)) }

        // Чужой ключ сессии с подделанной подписью.
        var key = try Base64.decode(outbound.sessionKey())
        key[10] ^= 1
        #expect(throws: CryptoError.badSignature) { try MegolmInboundSession(sessionKey: Base64.encodeUnpadded(key)) }
    }

    @Test func protobufVarints() throws {
        for value: UInt64 in [0, 1, 127, 128, 300, 16_384, UInt64(UInt32.max)] {
            var out = Data()
            Protobuf.appendVarint(value, to: &out)
            var reader = Protobuf.Reader(out)
            #expect(try reader.varint() == value)
        }
    }
}
