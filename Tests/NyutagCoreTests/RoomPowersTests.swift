// Права в группе: роли, кто кого может выгнать и назначить, «пишут только админы», закреплённые реплики.

import Foundation
@testable import NyutagCore
import Testing

@Suite("Права в группе")
struct RoomPowersTests {
    let owner = "@owner:nyutag.chat"
    let admin = "@admin:nyutag.chat"
    let mod = "@mod:nyutag.chat"
    let user = "@user:nyutag.chat"

    var powers: RoomPowers {
        RoomPowers(powerLevels: [
            "users": [.init(stringLiteral: admin): 100, .init(stringLiteral: mod): 50],
            "users_default": 0, "events_default": 0, "state_default": 50,
            "kick": 50, "ban": 50, "redact": 50, "invite": 0,
            "events": ["m.room.power_levels": 100, "m.room.name": 50],
        ], creators: [owner])
    }

    @Test("роли: создатель — владелец, 100 — админ, 50 — модератор, остальные — участники")
    func roles() {
        #expect(powers.role(of: owner) == .owner)
        #expect(powers.role(of: admin) == .admin)
        #expect(powers.role(of: mod) == .moderator)
        #expect(powers.role(of: user) == .member)
        #expect(RoomPowers(powerLevels: nil).role(of: user) == .member)
    }

    @Test("выгнать и заблокировать можно только того, кто ниже")
    func kickBan() {
        #expect(powers.canKick(owner, admin))
        #expect(powers.canKick(admin, mod))
        #expect(powers.canBan(mod, user))
        #expect(!powers.canKick(mod, admin))
        #expect(!powers.canKick(admin, owner))
        #expect(!powers.canKick(user, user))
        #expect(!powers.canBan(user, mod))
        #expect(powers.canRedactOthers(mod))
        #expect(!powers.canRedactOthers(user))
    }

    @Test("назначать: нужен уровень на power_levels, не выше своего, цель ниже; создателя не трогаем")
    func setLevel() {
        #expect(powers.canSetLevel(owner, admin, to: 0))
        #expect(powers.canSetLevel(admin, user, to: 100))
        #expect(powers.canSetLevel(admin, admin, to: 0))
        #expect(!powers.canSetLevel(admin, owner, to: 0))
        #expect(!powers.canSetLevel(mod, user, to: 50))
        #expect(!powers.canSetLevel(admin, "@peer:nyutag.chat", to: 101))
    }

    @Test("назначение пишет в users, уровень по умолчанию убирает запись")
    func setting() {
        let promoted = RoomPowers(powerLevels: powers.setting(user, to: 100), creators: [owner])
        #expect(promoted.role(of: user) == .admin)
        #expect(promoted.content["kick"]?.int == 50)
        let demoted = powers.setting(admin, to: 0)
        #expect(demoted["users"]?[admin] == nil)
        #expect(demoted["users"]?[mod]?.int == 50)
    }

    @Test("пишут только админы: реплики с 50, реакции всем; выключение возвращает как было")
    func onlyAdmins() {
        #expect(!powers.onlyAdminsWrite)
        let closed = RoomPowers(powerLevels: powers.writing(onlyAdmins: true))
        #expect(closed.onlyAdminsWrite)
        #expect(!closed.canSend(user))
        #expect(closed.canSend(user, event: EventType.reaction))
        #expect(closed.content["events"]?["m.room.name"]?.int == 50)
        let open = RoomPowers(powerLevels: closed.writing(onlyAdmins: false))
        #expect(!open.onlyAdminsWrite)
        #expect(open.canSend(user))
        #expect(open.content["events"]?[EventType.reaction] == nil)
    }

    @Test("смена названия по events, остальное по state_default")
    func state() {
        #expect(powers.canSetState(mod, type: EventType.name))
        #expect(!powers.canSetState(mod, type: EventType.powerLevels))
        #expect(powers.canSetState(mod, type: EventType.topic))
        #expect(!powers.canSetState(user, type: EventType.topic))
    }

    @Test("закрепление: новое первым, без повторов, снятие")
    func pins() {
        var content = PinnedEvents.pinning("$a", true, in: nil)
        content = PinnedEvents.pinning("$b", true, in: content)
        content = PinnedEvents.pinning("$a", true, in: content)
        #expect(PinnedEvents.ids(content) == ["$a", "$b"])
        #expect(PinnedEvents.ids(PinnedEvents.pinning("$a", false, in: content)) == ["$b"])
    }

    @Test("состав: внутри, заявки, заблокированные; без имени — ник")
    func roster() {
        func member(_ user: String, _ membership: String, _ name: String? = nil) -> Event {
            var content: [String: JSONValue] = ["membership": .string(membership)]
            if let name { content["displayname"] = .string(name) }
            return Event(type: EventType.member, sender: user, stateKey: user, content: .object(content))
        }
        let roster = Roster([member(user, "join", "Ян"), member(mod, "join", "Аюр"), member(admin, "knock"),
                             member(owner, "ban"), member("@gone:nyutag.chat", "leave")])
        #expect(roster.joined.map(\.name) == ["Аюр", "Ян"])
        #expect(roster.knocking.map(\.name) == ["admin"])
        #expect(roster.banned.map(\.userID) == [owner])
        #expect(roster.invited.isEmpty)
    }

    @Test("ссылка на сообщество: сайт и приложение дают один id")
    func communityLink() {
        let id = "!9qE29BLZcWtl8B3QGXxgiJOmuGfG2d-ba_c-_WKfp0s:nyutag.chat"
        let web = CommunityLink.web(id)
        #expect(web.absoluteString.hasPrefix("https://nyutag.chat/c/#"))
        #expect(CommunityLink.roomID(from: web) == id)
        #expect(CommunityLink.roomID(from: URL(string: "nyutag://community/" + id)!) == id)
        let v12 = "!m6hl-9fSCLT2wJcyTNukpgT3DBDqbYs-KJ1GT7TaJr4"
        #expect(CommunityLink.roomID(from: CommunityLink.web(v12)) == v12)
        #expect(CommunityLink.roomID(from: URL(string: "nyutag://community/" + v12)!) == v12)
        #expect(CommunityLink.roomID(from: URL(string: "nyutag://invite/ABC")!) == nil)
        #expect(CommunityLink.roomID(from: URL(string: "https://nyutag.chat/i/#ABC")!) == nil)
    }
}
