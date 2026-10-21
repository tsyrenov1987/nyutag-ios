// Нютаг. Голосовые: волна из уровней записи, формат MSC3245 туда и обратно.

import Foundation
import Testing
@testable import NyutagCore

@Suite struct VoiceTests {
    @Test("волна: тишина 0, максимум 1024, длинная запись сжимается до сотни")
    func waveform() {
        #expect(Voice.waveform(decibels: [-160, 0, -25, .nan]) == [0, 1024, 512, 0])
        let long = Voice.waveform(decibels: Array(repeating: -25, count: 1000))
        #expect(long.count == 100 && long.allSatisfy { $0 == 512 })
        #expect(Voice.waveform(decibels: []) == [])
        #expect(Voice.display([], bars: 3) == [0.15, 0.15, 0.15])
        #expect(Voice.display([0, 1024], bars: 4) == [0.08, 0.08, 1, 1])
        #expect(Voice.clock(83_400) == "1:23")
        #expect(Voice.clock(7_000) == "0:07")
    }

    @Test("голосовое: метка, волна и длительность туда и обратно")
    func roundTrip() throws {
        let mxc = try #require(MXC("mxc://nyutag.chat/abc"))
        let content = Attachment.content(.plain(mxc), name: "Голосовое.m4a", mimetype: "audio/mp4", size: 1200,
                                         duration: 4200, voice: [10, 500, 1024])
        #expect(content["msgtype"]?.string == "m.audio")
        #expect(content["org.matrix.msc3245.voice"] == [:])
        #expect(content["org.matrix.msc1767.audio"]?["duration"]?.int == 4200)
        let read = try #require(Attachment.read(content))
        #expect(read.isVoice && read.waveform == [10, 500, 1024] && read.duration == 4200)
    }

    @Test("чужое голосовое без info.duration и с выбросами в волне")
    func foreign() throws {
        let content: JSONValue = ["msgtype": "m.audio", "body": "Voice message", "url": "mxc://x/1",
                                  "org.matrix.msc3245.voice": [:],
                                  "org.matrix.msc1767.audio": ["duration": 3000, "waveform": [-5, 2000, 300]]]
        let read = try #require(Attachment.read(content))
        #expect(read.duration == 3000 && read.waveform == [0, 1024, 300])
        let music = try #require(Attachment.read(["msgtype": "m.audio", "body": "song.mp3", "url": "mxc://x/2"]))
        #expect(!music.isVoice)
    }
}
