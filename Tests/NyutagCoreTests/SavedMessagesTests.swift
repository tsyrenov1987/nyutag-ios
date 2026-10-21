import Foundation
@testable import NyutagCore
import Testing

@Suite struct SavedMessagesTests {
    @Test func readsAndroidFormat() throws {
        let json = try JSONValue(parsing: #"{"room_id":"!abc:nyutag.chat","extra":1}"#)
        #expect(SavedMessages.roomID(json: json) == "!abc:nyutag.chat")
        #expect(SavedMessages.roomID(json: SavedMessages.json(roomID: "!x:y")) == "!x:y")
        #expect(SavedMessages.roomID(json: nil) == nil)
        #expect(SavedMessages.roomID(json: try JSONValue(parsing: #"{"room_id":""}"#)) == nil)
        #expect(SavedMessages.roomID(json: try JSONValue(parsing: #"{"room_id":5}"#)) == nil)
    }

    @Test func renamesOnlyDefaultNames() {
        #expect(SavedMessages.needsRename("Saved messages", to: "Избранное"))
        #expect(SavedMessages.needsRename("Хадагалһан", to: "Избранное"))
        #expect(!SavedMessages.needsRename("Избранное", to: "Избранное"))
        #expect(!SavedMessages.needsRename("Мои заметки", to: "Избранное"))
    }
}
