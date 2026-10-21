import Foundation
@testable import NyutagCore
import Testing

@Suite struct ProfileAboutTests {
    @Test func eastYearCycle() {
        #expect(EastYear(year: 1984).key == "wood-rat")
        #expect(EastYear(year: 1987).key == "fire-rabbit")
        #expect(EastYear(year: 2026).key == "fire-horse")
        #expect(EastYear(year: 2024).key == "wood-dragon")
        #expect(EastYear(year: 1923).key == "water-pig")
        #expect(EastYear(year: 1987) == EastYear(year: 2047))
        #expect(EastYear(key: "fire-horse") == EastYear(year: 2026))
        #expect(EastYear(key: "fire") == nil)
        #expect(EastYear(key: "lava-horse") == nil)
    }

    @Test func editsOnlyChanged() {
        let old = ProfileAbout(about: "Привет", toonto: "Хори", ug: "", eastYear: "fire-horse")
        var fresh = old
        fresh.about = "  Привет  "
        fresh.toonto = ""
        fresh.ug = " Хуасай "
        fresh.eastYear = "мусор"
        let edits = fresh.edits(from: old)
        #expect(edits.count == 3)
        #expect(edits[.toonto] == .some(nil))
        #expect(edits[.ug] == "Хуасай")
        #expect(edits[.eastYear] == .some(nil))
        #expect(edits[.about] == nil)
        #expect(ProfileAbout(about: String(repeating: "а", count: 600)).cleaned.about.count == ProfileAbout.maxAbout)
    }

    @Test func readsProfile() {
        let profile = Profile(fields: ["chat.nyutag.about": "Сайн", "chat.nyutag.east_year": "wood-rat", "chat.nyutag.ug": ""])
        #expect(ProfileAbout(profile: profile) == ProfileAbout(about: "Сайн", eastYear: "wood-rat"))
    }
}
