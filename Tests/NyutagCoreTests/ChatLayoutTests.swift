import Foundation
@testable import NyutagCore
import Testing

@Suite struct ChatLayoutTests {
    @Test func readsAndCleansAndroidFormat() throws {
        let json = try JSONValue(parsing: """
        {"pins":["!a","!b","!a","!c","!d","!e","!f","!g"],
         "folders":[{"id":"w","name":" Работа ","rooms":["!a","!a","!x"]},{"id":"","name":"пусто"},
                    {"id":"w","name":"повтор"},{"id":"f","name":"Семья"}],"chat.extra":1}
        """)
        let layout = ChatLayout(json: json)
        #expect(layout.pins == ["!a", "!b", "!c", "!d", "!e"])
        #expect(layout.folders == [ChatFolder(id: "w", name: "Работа", rooms: ["!a", "!x"]), ChatFolder(id: "f", name: "Семья")])
        // Пустые поля не пишем: папка без чатов — без "rooms".
        #expect(layout.json["folders"]?[1]?["rooms"] == nil)
        #expect(ChatLayout(json: layout.json) == layout)
        #expect(ChatLayout().json == .object([:]))
        #expect(ChatLayout(json: .string("мусор")) == ChatLayout())
    }

    @Test func pinsAndFolders() {
        var layout = ChatLayout()
        for room in ["!1", "!2", "!3", "!4", "!5", "!6"] { layout = layout.pinning(room, true) }
        #expect(layout.pins == ["!5", "!4", "!3", "!2", "!1"])
        #expect(!layout.canPinMore)
        layout = layout.pinning("!3", false).pinning("!6", true)
        #expect(layout.pins == ["!6", "!5", "!4", "!2", "!1"])

        layout = layout.addingFolder(id: "w", name: "  ", with: "!1")
        #expect(layout.folders.isEmpty)
        layout = layout.addingFolder(id: "w", name: "Работа", with: "!1").placing("!2", in: "w", true).placing("!1", in: "w", true)
        #expect(layout.folders.first?.rooms == ["!1", "!2"])
        layout = layout.placing("!1", in: "w", false).renamingFolder("w", to: "Дело")
        #expect(layout.folders == [ChatFolder(id: "w", name: "Дело", rooms: ["!2"])])
        #expect(layout.removingFolder("w").folders.isEmpty)
    }

    @Test func arrangePutsPinsOnTop() {
        let lines = ["!a", "!b", "!c", "!d"].map(Self.line)
        let layout = ChatLayout(pins: ["!c", "!gone", "!a"], folders: [ChatFolder(id: "w", name: "Работа", rooms: ["!d", "!a"])])
        #expect(layout.arrange(lines).map(\.id) == ["!c", "!a", "!b", "!d"])
        #expect(layout.arrange(lines, folder: "w").map(\.id) == ["!a", "!d"])
        #expect(layout.arrange(lines, folder: "нет").isEmpty)
    }

    static func line(_ id: String) -> ChatLine {
        ChatLine(id: id, title: id, avatarURL: nil, membership: .join, isDirect: false, isEncrypted: false, isSpace: false,
                 last: nil, lastSenderName: nil, lastIsMine: false, delivery: .none, lastTS: 0, unread: 0, mentions: 0)
    }
}
