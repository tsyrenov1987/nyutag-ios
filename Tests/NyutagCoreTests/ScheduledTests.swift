import Foundation
@testable import NyutagCore
import Testing

@Suite struct ScheduledTests {
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func queueOrderAndDue() {
        let later = ScheduledMessage(id: "b", account: "@a:x", roomID: "!r", body: "потом", sendAt: Self.start.addingTimeInterval(3600))
        let soon = ScheduledMessage(id: "a", account: "@a:x", roomID: "!r", body: "скоро", sendAt: Self.start.addingTimeInterval(60))
        let other = ScheduledMessage(id: "c", account: "@b:x", roomID: "!r", body: "чужое", sendAt: Self.start)
        let queue = ScheduledQueue([later, soon, other, soon])
        #expect(queue.messages.map(\.id) == ["c", "a", "b"])
        #expect(queue.inRoom("!r", account: "@a:x").map(\.id) == ["a", "b"])
        #expect(queue.due(account: "@a:x", now: Self.start).isEmpty)
        #expect(queue.due(account: "@a:x", now: Self.start.addingTimeInterval(61)).map(\.id) == ["a"])
        #expect(queue.nextDue(account: "@a:x") == soon.date)

        let now = queue.sendingNow("b", now: Self.start)
        #expect(now.due(account: "@a:x", now: Self.start).map(\.id) == ["b"])
        #expect(now.removing("b").messages.map(\.id) == ["c", "a"])
        #expect(queue.removingAccount("@a:x").messages.map(\.id) == ["c"])
        #expect(soon.transactionID == "scheduled-a")
    }

    @Test func survivesStorage() throws {
        let message = ScheduledMessage(account: "@a:x", roomID: "!r", body: "привет\n«мир»", sendAt: Self.start)
        let queue = ScheduledQueue([message])
        #expect(ScheduledQueue(data: queue.data) == queue)
        // Битая запись выпадает, остальные живут.
        let mixed = try JSONValue(parsing: #"[{"id":"x"},{"id":"y","account":"@a:x","room":"!r","body":"ок","at":5}]"#).data()
        #expect(ScheduledQueue(data: mixed).messages.map(\.id) == ["y"])
        #expect(ScheduledQueue(data: Data("мусор".utf8)).messages.isEmpty)
        #expect(ScheduledQueue(data: nil).messages.isEmpty)
    }
}
