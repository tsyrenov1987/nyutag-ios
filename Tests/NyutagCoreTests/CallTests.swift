import Foundation
@testable import NyutagCore
import Testing

/// Звонки: события, ключи, кадры, буфер, кодек.
@Suite struct CallTests {
    @Test func signalsRoundTrip() throws {
        let id = CallID.make()
        let key = Data(repeating: 7, count: 32)
        for signal in [CallSignal.ring(callID: id, video: false, lifetime: .seconds(45)),
                       .offer(callID: id, key: key, video: true),
                       .answer(callID: id, key: key, deviceID: "DEV"),
                       .end(callID: id, reason: .declined)] {
            #expect(CallSignal(type: signal.eventType, content: signal.content) == signal)
        }
        #expect(CallSignal.ring(callID: id, video: false, lifetime: .seconds(45)).wantsRoomEncryption == false)
        #expect(CallSignal.offer(callID: id, key: key, video: false).wantsRoomEncryption)
        // Короткий ключ, чужой тип, плохой id — не наше.
        #expect(CallSignal(type: CallEventType.offer, content: ["call_id": .string(id), "key": "AAAA"]) == nil)
        #expect(CallSignal(type: "m.call.invite", content: ["call_id": .string(id)]) == nil)
        #expect(CallSignal(type: CallEventType.end, content: ["call_id": "a b"]) == nil)
        // Будильник Android-клиента без call_id не поднимает наш экран.
        #expect(CallSignal(type: CallEventType.ring, content: ["lifetime": 90000, "m.call.intent": "audio"]) == nil)
    }

    @Test func staleRingDoesNotRing() {
        let ring = CallSignal.ring(callID: CallID.make(), video: false, lifetime: .seconds(45))
        let now = Date()
        let fresh = CallMessage(signal: ring, roomID: "!r", sender: "@a", timestamp: Int(now.timeIntervalSince1970 * 1000) - 5_000)
        let old = CallMessage(signal: ring, roomID: "!r", sender: "@a", timestamp: Int(now.timeIntervalSince1970 * 1000) - 60_000)
        #expect(fresh.isRinging(now: now))
        #expect(!old.isRinging(now: now))
    }

    @Test func bothSidesDeriveMatchingKeys() throws {
        let caller = CallKeyPair(), callee = CallKeyPair()
        let id = CallID.make()
        let a = try caller.secret(with: callee.publicKey, callID: id, isCaller: true)
        let b = try callee.secret(with: caller.publicKey, callID: id, isCaller: false)
        #expect(a.slot == b.slot && a.slot.count == 32)
        var sendA = CallCipher(a), sendB = CallCipher(b)
        let sealed = sendA.seal(.audio, Data("алло".utf8))
        let packet = try #require(sealed)
        let opened = try #require(CallCipher(b).open(packet))
        #expect(opened.kind == .audio && opened.sequence == 0 && opened.payload == Data("алло".utf8))
        let sealedSecond = sendA.seal(.audio, Data([1]))
        let second = try #require(sealedSecond)
        #expect(CallCipher(b).open(second)?.sequence == 1)
        // Своё не открывается своим ключом приёма, подмена байта ломает метку, другой звонок — другой слот.
        #expect(CallCipher(a).open(packet) == nil)
        var bad = packet
        bad[6] ^= 1
        #expect(CallCipher(b).open(bad) == nil)
        var header = packet
        header[4] ^= 1
        #expect(CallCipher(b).open(header) == nil)
        let sealedReply = sendB.seal(.audio, Data("слышу".utf8))
        let reply = try #require(sealedReply)
        #expect(CallCipher(a).open(reply)?.payload == Data("слышу".utf8))
        #expect(try caller.secret(with: callee.publicKey, callID: CallID.make(), isCaller: true).slot != a.slot)
    }

    @Test func jitterReordersAndFillsGaps() {
        var buffer = JitterBuffer(target: 3, limit: 8)
        #expect(buffer.pull() == .waiting)
        buffer.insert(1, Data([1]))
        buffer.insert(0, Data([0]))
        #expect(buffer.pull() == .waiting)
        buffer.insert(3, Data([3]))
        #expect(buffer.pull() == .frame(Data([0])))
        #expect(buffer.pull() == .frame(Data([1])))
        #expect(buffer.pull() == .missing)
        // Опоздавший второй уже не нужен.
        buffer.insert(2, Data([2]))
        #expect(buffer.pull() == .frame(Data([3])))
        #expect(buffer.pull() == .waiting)
        #expect(buffer.lost == 1 && buffer.dropped == 1)
        // Затор: держим не больше limit, догоняем до свежих.
        for seq in UInt32(10)..<UInt32(30) { buffer.insert(seq, Data([UInt8(seq)])) }
        #expect(buffer.depth <= 8)
        // Старые кадры затора выброшены: играем с хвоста, а не с десятого.
        guard case .frame(let first) = buffer.pull() else { Issue.record("нет кадра"); return }
        #expect(first[0] >= 20)
    }

    @Test func opusRoundTripKeepsTone() throws {
        let encoder = try #require(VoiceEncoder())
        let decoder = try #require(VoiceDecoder())
        var decoded: [Float] = []
        var sizes: [Int] = []
        for frame in 0..<25 {
            let tone = (0..<VoiceFormat.frameSamples).map { i in
                0.3 * sin(Float(frame * VoiceFormat.frameSamples + i) * 2 * .pi * 440 / 48_000)
            }
            let packet = try #require(tone.withUnsafeBufferPointer { encoder.encode($0) })
            sizes.append(packet.count)
            decoded += decoder.decode(packet)
        }
        #expect(sizes.allSatisfy { $0 > 10 && $0 < 400 })
        let tail = decoded.suffix(9_600)
        let rms = sqrt(tail.map { $0 * $0 }.reduce(0, +) / Float(tail.count))
        // Синус 0,3 даёт ~0,21.
        #expect(rms > 0.15 && rms < 0.3)
    }
}
