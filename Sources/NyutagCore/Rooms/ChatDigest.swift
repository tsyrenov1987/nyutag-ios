// Нютаг. Строки списка чатов из локальной базы: заголовок, последняя реплика, счётчики.
// Работает без сети: список на запуске строится до первого /sync. Расшифровку подставляет приложение
// (машину держит оно); если ключа нет, реплика остаётся `.locked`, а подпись выбирает интерфейс.

import Foundation

public struct ChatLine: Sendable, Equatable, Identifiable {
    /// Судьба своей последней реплики (галочки в списке): дошла до сервера или её уже прочитали.
    public enum Delivery: Sendable, Equatable { case none, sent, read }

    public let id: String
    /// Пусто, если у комнаты нет ни имени, ни собеседников (интерфейс пишет «Пустой чат»).
    public let title: String
    public let avatarURL: String?
    public let membership: RoomRecord.Membership
    public let isDirect: Bool
    public let isEncrypted: Bool
    public let isSpace: Bool
    /// Последняя показываемая реплика; `nil` — в базе пока нет ни одной.
    public let last: PushPreview.Kind?
    public let lastSenderName: String?
    public let lastIsMine: Bool
    public let delivery: Delivery
    public let lastTS: Int
    public let unread: Int
    public let mentions: Int
}

public enum ChatDigest {
    /// Сколько последних событий просматривать в поисках реплики (реакции и служебные события пропускаются).
    /// Один звонок оставляет пачку сигналов (ring + шифрованные offer/answer/end), поэтому окно с запасом:
    /// цикл всё равно останавливается на первой реплике.
    static let lookback = 300

    /// Все комнаты, кроме покинутых: приглашения сверху, дальше по времени последнего события.
    public static func lines(store: Store, me: String,
                             decrypt: @Sendable (Event, String) async -> Event? = { _, _ in nil }) async throws -> [ChatLine] {
        var lines: [ChatLine] = []
        for record in try await store.rooms() where record.membership != .leave {
            lines.append(try await line(for: record, store: store, me: me, decrypt: decrypt))
        }
        return lines.sorted { a, b in
            if (a.membership == .invite) != (b.membership == .invite) { return a.membership == .invite }
            if a.lastTS != b.lastTS { return a.lastTS > b.lastTS }
            return a.id < b.id
        }
    }

    static func line(for record: RoomRecord, store: Store, me: String,
                     decrypt: @Sendable (Event, String) async -> Event?) async throws -> ChatLine {
        let members = try await store.state(record.id, type: EventType.member)
        var names: [String: String] = [:]
        for member in members {
            if let name = member.content["displayname"]?.string, !name.isEmpty { names[member.stateKey] = name }
        }
        func name(of userID: String) -> String { names[userID] ?? localpart(userID) }

        var last: PushPreview.Kind?
        var lastEvent: Event?
        // Идём от новых к старым: удаления и правки встречаются раньше реплик, к которым относятся.
        var removed: Set<String> = []
        var edits: [String: Event] = [:]
        for event in try await store.events(in: record.id, limit: lookback).reversed() {
            if event.type == EventType.redaction {
                if let target = event.content["redacts"]?.string ?? event.unsigned?["redacts"]?.string { removed.insert(target) }
                continue
            }
            if event.isRedacted || event.eventID.map(removed.contains) == true { continue }
            var shown = event
            var kind: PushPreview.Kind
            if event.type == EventType.encrypted {
                if let opened = await decrypt(event, record.id) {
                    shown = opened
                    kind = PushReader.kind(of: opened, me: me)
                } else {
                    kind = .locked
                }
            } else {
                kind = PushReader.kind(of: event, me: me)
            }
            if isEdit(shown) {
                if let target = shown.content["m.relates_to"]?["event_id"]?.string, edits[target] == nil { edits[target] = shown }
                continue
            }
            // Удалённое не показываем, правку — только от автора реплики.
            if let id = shown.eventID, let edit = edits[id], edit.sender == shown.sender,
               let fresh = edit.content["m.new_content"] {
                shown = Event(eventID: shown.eventID, type: shown.type, sender: shown.sender,
                              originServerTS: shown.originServerTS, content: fresh, roomID: shown.roomID)
                kind = PushReader.kind(of: shown, me: me)
            }
            if kind == .other || kind == .signal { continue }
            // Своё старое приглашение в чате, куда уже вошли, — не реплика.
            if kind == .invite, record.membership != .invite { continue }
            last = kind
            lastEvent = shown
            break
        }

        let title: String
        if let roomName = record.name, !roomName.isEmpty {
            title = roomName
        } else if let alias = record.canonicalAlias, !alias.isEmpty {
            title = alias
        } else {
            var others = record.heroes.filter { $0 != me }
            if others.isEmpty {
                others = members.filter { member in
                    member.stateKey != me && ["join", "invite"].contains(member.content["membership"]?.string ?? "")
                }.map(\.stateKey).sorted()
            }
            title = others.prefix(3).map(name(of:)).joined(separator: ", ")
        }

        let sender = lastEvent?.sender
        var delivery = ChatLine.Delivery.none
        if let lastEvent, sender == me {
            delivery = try await isRead(lastEvent, roomID: record.id, members: members, me: me, store: store) ? .read : .sent
        }
        return ChatLine(id: record.id, title: title, avatarURL: record.avatarURL, membership: record.membership,
                        isDirect: record.isDirect, isEncrypted: record.isEncrypted, isSpace: record.isSpace,
                        last: last, lastSenderName: sender.map(name(of:)), lastIsMine: sender == me, delivery: delivery,
                        lastTS: lastEvent?.originServerTS ?? record.latestTS,
                        unread: record.notificationCount, mentions: record.highlightCount)
    }

    /// Прочитано, если кто-то из участников отметил прочтение этой реплики или более поздней.
    static func isRead(_ event: Event, roomID: String, members: [(stateKey: String, sender: String?, content: JSONValue)],
                       me: String, store: Store) async throws -> Bool {
        let sentAt = event.originServerTS ?? 0
        for member in members where member.stateKey != me && member.content["membership"]?.string == "join" {
            guard let receipted = try await store.receipt(roomID: roomID, userID: member.stateKey)
            else { continue }
            if receipted == event.eventID { return true }
            if let seen = try await store.event(receipted), (seen.originServerTS ?? 0) >= sentAt { return true }
        }
        return false
    }

    /// Правка уже показанной реплики не двигает список: последней остаётся сама реплика.
    static func isEdit(_ event: Event) -> Bool {
        event.content["m.relates_to"]?["rel_type"]?.string == "m.replace"
    }

    /// `@arjuna:nyutag.chat` → `arjuna`.
    public static func localpart(_ userID: String) -> String {
        let trimmed = userID.hasPrefix("@") ? userID.dropFirst() : Substring(userID)
        return String(trimmed.split(separator: ":", maxSplits: 1).first ?? trimmed)
    }
}
