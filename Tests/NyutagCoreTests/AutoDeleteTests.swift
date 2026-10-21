import Foundation
@testable import NyutagCore
import Testing

@Suite struct AutoDeleteTests {
    @Test func readsAndroidFormat() throws {
        let rule = AutoDelete(json: try JSONValue(parsing: #"{"ttl":86400,"since":1700000000000.0}"#))
        #expect(rule == AutoDelete(ttl: AutoDelete.day, since: 1_700_000_000_000))
        #expect(AutoDelete(json: rule.json) == rule)
        #expect(AutoDelete(json: nil) == AutoDelete())
        #expect(!AutoDelete(json: .string("мусор")).isOn)
        #expect(AutoDelete(ttl: 3600).choice == AutoDelete.day)
        #expect(AutoDelete(ttl: 40 * AutoDelete.day).choice == AutoDelete.month)
        #expect(AutoDelete.starting(0) == AutoDelete())
    }

    @Test func hidesOnlyMessagesAfterSince() {
        let since = 1_000_000
        let rule = AutoDelete(ttl: 60, since: since)
        let now = Date(timeIntervalSince1970: TimeInterval(since + 120_000) / 1000)
        let items = [
            Self.item("старое", ts: since - 5_000, mine: true),
            Self.item("в ту же секунду", ts: since - 500, mine: true),
            Self.item("чужое", ts: since + 10_000, mine: false),
            Self.item("свежее", ts: since + 100_000, mine: true),
            Self.item("плашка", ts: since + 1_000, mine: false, notice: true),
        ]
        #expect(rule.visible(items, now: now).map(\.id) == ["старое", "свежее", "плашка"])
        #expect(rule.ownToDelete(items, now: now) == ["в ту же секунду"])
        let next = rule.nextExpiry(rule.visible(items, now: now))
        #expect(next == Date(timeIntervalSince1970: TimeInterval(since + 160_000) / 1000))
        #expect(AutoDelete().visible(items, now: now) == items)
    }

    static func item(_ id: String, ts: Int, mine: Bool, notice: Bool = false) -> FeedItem {
        FeedItem(id: id, sender: mine ? "@я" : "@он", senderName: "", isMine: mine, ts: ts,
                 body: notice ? .notice(.joined("он")) : .text(id), edited: false, reply: nil, reactions: [],
                 attachment: nil, isRead: false)
    }
}
