import Foundation
@testable import NyutagCore
import Testing

@Suite struct InviteLinkTests {
    @Test func linkRoundTrip() throws {
        let invite = InviteCode(code: "AB12-CD34", expiresAt: nil)
        #expect(invite.link == "https://nyutag.chat/i/#AB12-CD34")
        #expect(InviteCode.code(fromLink: try #require(URL(string: invite.link))) == "AB12-CD34")
    }

    @Test func readsBothForms() throws {
        func code(_ text: String) throws -> String? { InviteCode.code(fromLink: try #require(URL(string: text))) }
        #expect(try code("nyutag://invite/ab12cd34") == "AB12CD34")
        #expect(try code("nyutag://invite/AB12-CD34/") == "AB12-CD34")
        #expect(try code("https://nyutag.chat/i#ab12-cd34") == "AB12-CD34")
        #expect(try code("https://nyutag.chat/i/") == nil)
        #expect(try code("https://evil.example/i/#AB12-CD34") == nil)
        #expect(try code("nyutag://room/AB12-CD34") == nil)
        #expect(try code("nyutag://invite/AB12-CD34-XX") == nil)
        #expect(try code("http://nyutag.chat/i/#AB12-CD34") == nil)
    }
}
