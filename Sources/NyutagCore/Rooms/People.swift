// Нютаг. Люди для вкладки «Контакты»: с кем уже есть личный чат, кого сервер нашёл по номерам из телефонной
// книги и кто нашёлся поиском по имени. Номера сравниваем в том же виде, что и сервер (+7… для российских).

import Foundation

/// Человек в Нютаге.
public struct Person: Sendable, Equatable, Identifiable {
    public let userID: String
    /// Имя из телефонной книги, иначе из профиля, иначе ник.
    public var name: String
    public var avatarURL: String?
    /// Номер из книжки, по которому человек нашёлся.
    public var phone: String?
    /// Уже есть личный чат, куда мы вошли или куда нас позвали.
    public var directRoom: String?

    public var id: String { userID }

    public init(userID: String, name: String, avatarURL: String? = nil, phone: String? = nil, directRoom: String? = nil) {
        self.userID = userID
        self.name = name
        self.avatarURL = avatarURL
        self.phone = phone
        self.directRoom = directRoom
    }
}

/// Запись телефонной книги: имя и номера, как их записал человек.
public struct BookEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let phones: [String]

    public init(id: String, name: String, phones: [String]) {
        self.id = id
        self.name = name
        self.phones = phones
    }
}

public enum People {
    /// Номер в виде, в каком его хранит сервер: `+` и 10–15 цифр; российские 8… и 9… приводим к +7.
    public static func phoneKey(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        var digits = trimmed.filter(\.isASCII).filter(\.isNumber)
        if trimmed.hasPrefix("+") {
            // Код страны уже есть.
        } else if digits.count == 11, digits.first == "7" || digits.first == "8" {
            digits = "7" + digits.dropFirst()
        } else if digits.count == 10, digits.first == "9" {
            digits = "7" + digits
        }
        return (10...15).contains(digits.count) ? "+" + digits : nil
    }

    /// Все разные номера книжки, по одному на нормальный вид: столько уйдёт на сверку.
    public static func uniquePhones(_ book: [BookEntry]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for entry in book {
            for phone in entry.phones {
                if let key = phoneKey(phone), seen.insert(key).inserted { result.append(phone) }
            }
        }
        return result
    }

    /// Собеседники из `m.direct`: комната, где мы ещё состоим, и имя из её участников.
    public static func known(store: Store, me: String) async throws -> [Person] {
        let direct = try await store.accountData(EventType.direct)?.object ?? [:]
        var people: [Person] = []
        for (userID, rooms) in direct where userID != me {
            var found: (room: String, name: String?, avatar: String?)?
            for roomID in (rooms.array ?? []).compactMap(\.string) {
                guard let record = try await store.room(roomID), [.join, .invite].contains(record.membership) else { continue }
                let member = try await store.state(roomID, type: EventType.member, stateKey: userID)
                found = (roomID, member?["displayname"]?.string, member?["avatar_url"]?.string)
                if record.membership == .join { break }
            }
            guard let found else { continue }
            let name = found.name.flatMap { $0.isEmpty ? nil : $0 } ?? ChatDigest.localpart(userID)
            people.append(Person(userID: userID, name: name, avatarURL: found.avatar, directRoom: found.room))
        }
        return people
    }

    /// Кто в Нютаге: собеседники плюс найденные по номерам. Имя из книжки главнее имени из профиля.
    /// Остальные записи книжки — те, кого можно позвать.
    public static func merge(book: [BookEntry], matches: [String: String],
                             known: [Person]) -> (inNyutag: [Person], invite: [BookEntry]) {
        var byID: [String: Person] = [:]
        for person in known { byID[person.userID] = person }
        let byKey = Dictionary(matches.compactMap { phone, user in phoneKey(phone).map { ($0, user) } },
                               uniquingKeysWith: { first, _ in first })
        var invite: [BookEntry] = []
        for entry in book {
            let hit = entry.phones.lazy.compactMap { phone in phoneKey(phone).flatMap { byKey[$0] }.map { (phone, $0) } }.first
            guard let (phone, userID) = hit else {
                invite.append(entry)
                continue
            }
            var person = byID[userID] ?? Person(userID: userID, name: entry.name)
            if !entry.name.isEmpty { person.name = entry.name }
            person.phone = person.phone ?? phone
            byID[userID] = person
        }
        let order: (Person, Person) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return (byID.values.sorted(by: order), invite.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }

    /// Подходит ли человек под строку поиска: по имени, нику или цифрам номера.
    public static func matches(_ query: String, name: String, userID: String? = nil, phones: [String] = []) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        if name.localizedStandardContains(query) { return true }
        if let userID, userID.localizedStandardContains(query.hasPrefix("@") ? String(query.dropFirst()) : query) { return true }
        let digits = query.filter(\.isNumber)
        guard digits.count >= 3, digits.count == query.filter({ !" +-()".contains($0) }).count else { return false }
        // 8 912… и +7 912… — один номер: российский код в начале запроса не обязателен.
        let tail = "78".contains(digits.first!) ? String(digits.dropFirst()) : digits
        return phones.contains { phone in
            [phone.filter(\.isNumber), phoneKey(phone)?.filter(\.isNumber) ?? ""].contains { $0.contains(digits) || $0.contains(tail) }
        }
    }
}

public extension MatrixClient {
    /// POST /v3/user_directory/search: кого сервер покажет по имени или нику.
    func searchUsers(_ term: String, limit: Int = 20) async throws(MatrixError) -> [Person] {
        let json: JSONValue = try await request(.post, "user_directory/search",
                                                body: ["search_term": .string(term), "limit": .int(limit)])
        return (json["results"]?.array ?? []).compactMap { item in
            guard let userID = item["user_id"]?.string else { return nil }
            let name = item["display_name"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? ChatDigest.localpart(userID)
            return Person(userID: userID, name: name, avatarURL: item["avatar_url"]?.string)
        }
    }

    /// Человек по точному нику: каталог сервера показывает только тех, с кем есть общие комнаты,
    /// а ник новый знакомый мог продиктовать. Нет такого (404) — `nil`.
    func person(nick: String, server: String) async throws(MatrixError) -> Person? {
        let nick = Nickname.clean(nick)
        guard Nickname.isValid(nick) else { return nil }
        let userID = "@\(nick):\(server)"
        do {
            let json: JSONValue = try await request(.get, "profile/\(userID)")
            let name = json["displayname"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? nick
            return Person(userID: userID, name: name, avatarURL: json["avatar_url"]?.string)
        } catch where error.status == 404 {
            return nil
        }
    }
}
