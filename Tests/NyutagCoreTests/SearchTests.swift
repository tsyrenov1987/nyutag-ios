// Нютаг. Поиск по сообщениям: индекс собирается из открытых и расшифрованных реплик, правки и удаления учтены,
// реплика без ключа ждёт следующего прохода.

import Foundation
import Testing
@testable import NyutagCore

@Suite struct SearchTests {
    let me = "@me:nyutag.test"
    let friend = "@friend:nyutag.test"

    func message(_ id: String, _ text: String, room: String, ts: Int, sender: String? = nil) -> Event {
        Event(eventID: id, type: EventType.message, sender: sender ?? me, originServerTS: ts,
              content: ["msgtype": "m.text", "body": .string(text)], roomID: room)
    }

    @Test("открытые реплики: регистр и ё не мешают, удалённая не находится, правка ищется по новому тексту")
    func plainEditRedact() async throws {
        let store = try Store.inMemory()
        try await store.upsert(RoomRecord(id: "!a", membership: .join))
        try await store.upsert(RoomRecord(id: "!b", membership: .join))
        try await store.append([
            message("$1", "Привет, ёлка!", room: "!a", ts: 100),
            message("$2", "привет из второго чата", room: "!b", ts: 200, sender: friend),
            message("$3", "удали меня: привет", room: "!a", ts: 300),
            Event(eventID: "$4", type: EventType.redaction, sender: me, originServerTS: 400, content: ["redacts": "$3"], roomID: "!a"),
            message("$5", "старый текст", room: "!a", ts: 500),
            Event(eventID: "$6", type: EventType.message, sender: me, originServerTS: 600,
                  content: ["msgtype": "m.text", "body": "* новый привет", "m.new_content": ["msgtype": "m.text", "body": "новый привет"],
                            "m.relates_to": ["rel_type": "m.replace", "event_id": "$5"]], roomID: "!a"),
            Event(eventID: "$7", type: EventType.message, sender: me, originServerTS: 700,
                  content: ["msgtype": "m.image", "body": "privet.png", "url": "mxc://nyutag.test/p"], roomID: "!a"),
        ])
        // В индекс ложатся шесть: пять реплик (удалённая тоже, её отсекает поиск) и правка.
        let added = try await Search.index(store: store) { _, _ in nil }
        #expect(added == 6)
        let hits = try await Search.find("ПРИВЕТ", store: store)
        #expect(hits.map(\.eventID) == ["$5", "$2", "$1"])
        #expect(try await Search.find("privet", store: store).map(\.eventID) == ["$7"])
        #expect(hits.map(\.text).contains("новый привет"))
        #expect(try await Search.find("елка", store: store).map(\.eventID) == ["$1"])
        #expect(try await Search.find("привет", in: "!b", store: store).map(\.eventID) == ["$2"])
        #expect(try await Search.find("старый", store: store).isEmpty)
        #expect(try await Search.find("п", store: store).isEmpty)
        // Повторный проход ничего не добавляет: всё уже разобрано.
        #expect(try await Search.index(store: store) { _, _ in nil } == 0)
    }

    @Test("шифровка: без ключа ждёт, с ключом попадает в индекс")
    func encryptedWaitsForKey() async throws {
        let store = try Store.inMemory()
        try await store.upsert(RoomRecord(id: "!e", membership: .join))
        try await store.append([
            Event(eventID: "$c", type: EventType.encrypted, sender: friend, originServerTS: 100,
                  content: ["algorithm": "m.megolm.v1.aes-sha2", "ciphertext": "…"], roomID: "!e"),
        ])
        #expect(try await Search.index(store: store) { _, _ in nil } == 0)
        #expect(try await Search.find("тайна", store: store).isEmpty)
        let clear = message("$c", "большая тайна", room: "!e", ts: 100, sender: friend)
        #expect(try await Search.index(store: store) { _, _ in clear } == 1)
        let hits = try await Search.find("тайна", store: store)
        #expect(hits.count == 1)
        #expect(hits.first?.sender == friend)
        #expect(hits.first?.roomID == "!e")
    }
}
