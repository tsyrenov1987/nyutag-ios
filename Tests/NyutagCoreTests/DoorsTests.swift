// Двери: разбор строк каталога, слияние, память последней двери, порядок и гонка проб.

import Foundation
import Testing
@testable import NyutagCore

@Suite("Двери: каталог")
struct DoorCatalogueTests {
    @Test("Строка каталога: хост, порт, имя; без имени имя — хост")
    func parseLine() throws {
        let a = try #require(Door(line: "https://d4.assetnorth.org:6167#advin-d4"))
        #expect(a.url.host() == "d4.assetnorth.org")
        #expect(a.url.port == 6167)
        #expect(a.name == "advin-d4")
        let b = try #require(Door(line: "  https://k4.cdn-tvzvezda-ru.ru  "))
        #expect(b.url.port == nil)
        #expect(b.name == "k4.cdn-tvzvezda-ru.ru")
        #expect(Door(line: "https://k4.cdn-tvzvezda-ru.ru/#k4")?.url.path().isEmpty == true)
    }

    @Test("Не дверь: старый формат, http, путь, запрос, пустая строка")
    func rejects() {
        #expect(Door(line: "kilvater://abc@1.2.3.4:443?sni=x#old") == nil)
        #expect(Door(line: "http://d4.assetnorth.org:6167#x") == nil)
        #expect(Door(line: "https://d4.assetnorth.org/connect#x") == nil)
        #expect(Door(line: "https://d4.assetnorth.org?x=1#x") == nil)
        #expect(Door(line: "") == nil)
        #expect(Door(url: URL(string: "https:///nohost")!, name: "x") == nil)
    }

    @Test("Текст каталога: ключ, двери, комментарии и чужие строки пропущены")
    func parseText() throws {
        let text = """
        # каталог
        door-key abc123
        https://k4.cdn-tvzvezda-ru.ru#nsk-k4
        kilvater://old@1.2.3.4:443?sni=x#old
        https://d4.assetnorth.org:6167#advin-d4

        """
        let catalogue = try #require(DoorCatalogue(text: text))
        #expect(catalogue.key == "abc123")
        #expect(catalogue.doors.map(\.name) == ["nsk-k4", "advin-d4"])
        #expect(DoorCatalogue(text: "https://k4.cdn-tvzvezda-ru.ru#x") == nil, "без ключа каталога нет")
        #expect(DoorCatalogue(text: "door-key abc") == nil, "без дверей каталога нет")
    }

    @Test("Слияние: по адресу, порядок первого списка, новые в хвост")
    func merge() {
        let a = Door(line: "https://a.test#a")!, b = Door(line: "https://b.test#b")!, c = Door(line: "https://c.test#c")!
        let bAgain = Door(line: "https://b.test#b2")!
        #expect(DoorCatalogue.merge([a, b], [bAgain, c, a]) == [a, b, c])
        #expect(DoorCatalogue.merge([], [a, a]) == [a])
    }

    @Test("Память: последняя дверь с ключом и присланные двери, забывание")
    func memory() throws {
        let defaults = try #require(UserDefaults(suiteName: "chat.nyutag.tests.doors"))
        defer { defaults.removePersistentDomain(forName: "chat.nyutag.tests.doors") }
        DoorMemory.forget(in: defaults)
        #expect(DoorMemory.recall(from: defaults) == nil)
        #expect(DoorMemory.recallDynamic(from: defaults).isEmpty)
        let door = Door(line: "https://d4.assetnorth.org:6167#advin-d4")!
        DoorMemory.remember(door, key: "k", in: defaults)
        let back = try #require(DoorMemory.recall(from: defaults))
        #expect(back.door == door)
        #expect(back.key == "k")
        let fresh = [Door(line: "https://d15.assetnorth.org:6167#new")!]
        DoorMemory.rememberDynamic(fresh, in: defaults)
        #expect(DoorMemory.recallDynamic(from: defaults) == fresh)
        DoorMemory.forget(in: defaults)
        #expect(DoorMemory.recall(from: defaults) == nil)
        #expect(DoorMemory.recallDynamic(from: defaults).isEmpty)
    }
}

@Suite("Двери: гонка")
struct DoorRaceTests {
    private let a = Door(line: "https://a.test#a")!, b = Door(line: "https://b.test#b")!, c = Door(line: "https://c.test#c")!

    @Test("Порядок: предпочтительная первой, повторы убраны, чужая предпочтительная не добавляется")
    func order() {
        #expect(DoorRace.order([a, b, c, b], preferred: c) == [c, a, b])
        #expect(DoorRace.order([a, b], preferred: nil) == [a, b])
        let stranger = Door(line: "https://z.test#z")!
        #expect(DoorRace.order([a, b], preferred: stranger) == [a, b])
    }

    @Test("Побеждает первая ответившая, остальные пробы снимаются")
    func firstWins() async {
        let probed = Counter()
        let winner = await DoorRace.run([a, b, c], preferred: nil, headStart: .zero) { door in
            probed.add(door)
            if door == self.b { return true }
            try? await Task.sleep(for: .seconds(5))
            return !Task.isCancelled
        }
        #expect(winner == b)
        #expect(probed.count == 3, "без предпочтения все стартуют сразу")
    }

    @Test("Фора: предпочтительная успевает, остальные не дёргаются")
    func headStartKeepsPreferred() async {
        let probed = Counter()
        let winner = await DoorRace.run([a, b, c], preferred: c, headStart: .milliseconds(500)) { door in
            probed.add(door)
            return door == self.c
        }
        #expect(winner == c)
        #expect(probed.count == 1)
    }

    @Test("Фора: предпочтительная молчит, остальные стартуют после форы")
    func headStartExpires() async {
        let clock = ContinuousClock(), started = clock.now
        let winner = await DoorRace.run([a, b], preferred: a, headStart: .milliseconds(200)) { door in
            if door == self.a { try? await Task.sleep(for: .seconds(5)); return false }
            return true
        }
        #expect(winner == b)
        #expect(clock.now - started >= .milliseconds(200))
        #expect(clock.now - started < .seconds(4), "проигравшую пробу сняли, её сна не ждали")
    }

    @Test("Никто не ответил или дверей нет: nil")
    func nobody() async {
        #expect(await DoorRace.run([a, b], preferred: nil, headStart: .zero) { _ in false } == nil)
        #expect(await DoorRace.run([], preferred: a, headStart: .zero) { _ in true } == nil)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var doors: [Door] = []
    func add(_ door: Door) { lock.withLock { doors.append(door) } }
    var count: Int { lock.withLock { doors.count } }
}
