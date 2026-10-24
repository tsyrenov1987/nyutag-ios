// Нютаг. Лента одного чата из локальной базы: реплики и служебные плашки, уже собранные для показа.
// Правки подставлены в исходную реплику, удалённые помечены, реакции посчитаны, ответ несёт короткую цитату.
// Расшифровку, как и в списке чатов, подставляет приложение.

import Foundation

public struct FeedItem: Sendable, Equatable, Identifiable {
    /// Что случилось в комнате, кроме реплик. Имена уже человеческие.
    public enum Notice: Sendable, Equatable {
        case created(by: String)
        case joined(String)
        case left(String)
        case invited(String, by: String)
        case removed(String, by: String)
        case banned(String, by: String)
        case renamedSelf(from: String, to: String)
        case roomNamed(String, by: String)
        case roomPhoto(by: String)
        case roomTopic(String, by: String)
        case encryptionOn(by: String)
        /// Реплики до нашего входа: ключ к ним раздали без нас, ждать его бесполезно.
        case earlierLocked
    }

    public enum Body: Sendable, Equatable {
        case text(String)
        /// Вложение, стикер, опрос, звонок: вид и подпись, если есть.
        case attachment(PushPreview.Kind, caption: String?)
        /// Зашифровано, ключа пока нет.
        case locked
        case deleted
        case notice(Notice)
    }

    public struct Reaction: Sendable, Equatable {
        public let key: String
        public let count: Int
        public let mine: Bool
        /// Наша реакция с этим ключом: её удаляем, когда человек снимает реакцию.
        public let myEventID: String?

        public init(key: String, count: Int, mine: Bool, myEventID: String? = nil) {
            self.key = key
            self.count = count
            self.mine = mine
            self.myEventID = myEventID
        }
    }

    public struct Quote: Sendable, Equatable {
        public let eventID: String
        public let senderName: String
        public let preview: PushPreview.Kind
    }

    public let id: String
    public let sender: String
    public let senderName: String
    public let isMine: Bool
    public let ts: Int
    public let body: Body
    public let edited: Bool
    public let reply: Quote?
    public let reactions: [Reaction]
    /// Файл или картинка реплики, если она с вложением.
    public let attachment: Attachment?
    /// Только у своих реплик: прочитал ли кто-то из собеседников её или более позднюю.
    public let isRead: Bool
    /// Переслано из другого чата.
    public var forwarded = false

    public var isNotice: Bool { if case .notice = body { true } else { false } }

    /// Свой текст можно поправить.
    public var canEdit: Bool { if isMine, case .text = body { true } else { false } }

    /// Своё можно удалить, пока оно не удалено.
    public var canDelete: Bool { isMine && !isNotice && body != .deleted }
    /// Пожаловаться можно на чужую реплику, которую видно.
    public var canReport: Bool { !isMine && !isNotice && body != .deleted && body != .locked }
}

public enum ChatFeed {
    /// Последние `limit` событий комнаты, собранные в ленту: старые первыми.
    /// `ignored` — блокированные: их реплики, реакции и правки в ленту не попадают.
    public static func items(roomID: String, store: Store, me: String, limit: Int = 80, ignored: Set<String> = [],
                             decrypt: @Sendable (Event, String) async -> Event? = { _, _ in nil }) async throws -> [FeedItem] {
        let members = try await store.state(roomID, type: EventType.member)
        var names: [String: String] = [:]
        for member in members {
            if let name = member.content["displayname"]?.string, !name.isEmpty { names[member.stateKey] = name }
        }
        func name(of userID: String) -> String { names[userID] ?? ChatDigest.localpart(userID) }

        // В открытой комнате шифром идут только сигналы звонка: нерасшифрованное там не реплика.
        let sealedRoom = (try await store.room(roomID))?.isEncrypted != false
        var opened: [Event] = []
        for event in try await store.events(in: roomID, limit: limit) {
            if let sender = event.sender, ignored.contains(sender), event.type != EventType.member { continue }
            if event.type == EventType.encrypted, !event.isRedacted {
                if let clear = await decrypt(event, roomID) { opened.append(clear) } else if sealedRoom { opened.append(event) }
            } else {
                opened.append(event)
            }
        }

        // Сначала служебное о других событиях: правки, реакции, удаления.
        var edits: [String: JSONValue] = [:]
        var reactions: [String: [String: (count: Int, mine: String?)]] = [:]
        var reactionOrder: [String: [String]] = [:]
        var removed: Set<String> = []
        var authors: [String: String] = [:]
        for event in opened { if let id = event.eventID, let sender = event.sender { authors[id] = sender } }
        // Удаления — первыми: снятая реакция может стоять в ленте раньше своего удаления только по времени.
        for event in opened where event.type == EventType.redaction && !event.isRedacted {
            if let target = event.content["redacts"]?.string ?? event.unsigned?["redacts"]?.string { removed.insert(target) }
        }
        for event in opened where !event.isRedacted && !(event.eventID.map(removed.contains) ?? false) {
            let relation = event.content["m.relates_to"]
            switch event.type {
            case EventType.redaction:
                continue
            case EventType.reaction:
                guard relation?["rel_type"]?.string == "m.annotation", let target = relation?["event_id"]?.string,
                      let key = relation?["key"]?.string else { continue }
                var byKey = reactions[target, default: [:]]
                if byKey[key] == nil { reactionOrder[target, default: []].append(key) }
                let old = byKey[key] ?? (0, nil)
                byKey[key] = (old.count + 1, old.mine ?? (event.sender == me ? event.eventID : nil))
                reactions[target] = byKey
            default:
                // Правку принимаем только от автора исходной реплики.
                if relation?["rel_type"]?.string == "m.replace", let target = relation?["event_id"]?.string,
                   let fresh = event.content["m.new_content"], authors[target] == nil || authors[target] == event.sender {
                    edits[target] = fresh
                }
            }
        }

        // Вход создателя сразу после создания — та же новость, что «чат создан».
        let creator = opened.first { $0.type == EventType.create }?.sender

        // Наш последний вход в комнату: ключи к репликам до него раздавали без нас.
        let joinedAt = opened.lastIndex {
            $0.type == EventType.member && $0.stateKey == me && $0.content["membership"]?.string == "join"
                && $0.unsigned?["prev_content"]?["membership"]?.string != "join"
        }
        var hidLocked = false

        let readUpTo = try await othersReadTS(roomID: roomID, members: members, me: me, store: store)
        var byID: [String: Event] = [:]
        for event in opened { if let id = event.eventID { byID[id] = event } }

        var items: [FeedItem] = []
        for (index, event) in opened.enumerated() {
            var shownContent = event.content
            guard let id = event.eventID, let sender = event.sender else { continue }
            if ChatDigest.isEdit(event) { continue }
            let body: FeedItem.Body
            if event.type == EventType.encrypted, !event.isRedacted, !removed.contains(id), let joinedAt, index < joinedAt {
                // Все такие реплики — одной плашкой на месте первой.
                if hidLocked { continue }
                hidLocked = true
                body = .notice(.earlierLocked)
            } else if event.isRedacted || removed.contains(id) {
                guard event.type == EventType.message || event.type == EventType.encrypted || event.type == EventType.sticker
                else { continue }
                body = .deleted
            } else if event.type == EventType.encrypted {
                body = .locked
            } else if let notice = notice(event, name: name(of:)) {
                if case .joined = notice, event.stateKey == creator, event.unsigned?["prev_content"]?["membership"] == nil {
                    continue
                }
                body = .notice(notice)
            } else if let shown = bubble(event, replaced: edits[id], me: me) {
                body = shown
                if let fresh = edits[id] { shownContent = fresh }
            } else {
                continue
            }
            var reply: FeedItem.Quote?
            if case .notice = body {} else if body != .deleted, let target = event.content["m.relates_to"]?["m.in_reply_to"]?["event_id"]?.string {
                var quoted = byID[target]
                if quoted == nil, let stored = try await store.event(target) {
                    quoted = stored.type == EventType.encrypted ? (await decrypt(stored, roomID) ?? stored) : stored
                }
                // Цитата показывает текст после правки.
                if let old = quoted, let fresh = edits[target], old.type != EventType.encrypted {
                    quoted = Event(eventID: old.eventID, type: old.type, sender: old.sender, originServerTS: old.originServerTS,
                                   stateKey: old.stateKey, content: fresh, unsigned: old.unsigned, roomID: old.roomID)
                }
                if let quoted, let author = quoted.sender {
                    let kind: PushPreview.Kind = quoted.type == EventType.encrypted ? .locked : PushReader.kind(of: quoted, me: me)
                    reply = FeedItem.Quote(eventID: target, senderName: name(of: author), preview: kind)
                }
            }
            let counted = reactionOrder[id, default: []].compactMap { key in
                reactions[id]?[key].map { FeedItem.Reaction(key: key, count: $0.count, mine: $0.mine != nil, myEventID: $0.mine) }
            }
            let ts = event.originServerTS ?? 0
            let attachment: Attachment? = if case .attachment(.sticker, _) = body { Attachment.sticker(shownContent) }
                else if case .attachment = body { Attachment.read(shownContent) } else { nil }
            items.append(FeedItem(id: id, sender: sender, senderName: name(of: sender), isMine: sender == me, ts: ts,
                                  body: body, edited: edits[id] != nil && body != .deleted, reply: reply,
                                  reactions: body == .deleted ? [] : counted,
                                  attachment: attachment,
                                  isRead: sender == me && readUpTo.map { ts <= $0 } == true,
                                  forwarded: body != .deleted && event.content[Forwarding.forwardedKey]?.bool == true))
        }
        return items
    }

    static func bubble(_ event: Event, replaced: JSONValue?, me: String) -> FeedItem.Body? {
        var shown = event
        if let replaced {
            shown = Event(eventID: event.eventID, type: event.type, sender: event.sender, originServerTS: event.originServerTS,
                          content: replaced, roomID: event.roomID)
        }
        let kind = PushReader.kind(of: shown, me: me)
        switch kind {
        case .text(let text): return .text(text)
        case .other, .invite, .locked, .signal: return nil
        default:
            let caption = shown.content["body"]?.string
            // Имя файла в body — не подпись; подпись есть, только если рядом лежит отдельное filename.
            let hasCaption = shown.content["filename"]?.string.map { $0 != caption } ?? false
            return .attachment(kind, caption: hasCaption ? caption : nil)
        }
    }

    static func notice(_ event: Event, name: (String) -> String) -> FeedItem.Notice? {
        guard let sender = event.sender else { return nil }
        let content = event.content
        switch event.type {
        case EventType.create:
            return .created(by: name(sender))
        case EventType.name:
            guard let title = content["name"]?.string, !title.isEmpty else { return nil }
            return .roomNamed(title, by: name(sender))
        case EventType.avatar:
            return .roomPhoto(by: name(sender))
        case EventType.topic:
            guard let topic = content["topic"]?.string, !topic.isEmpty else { return nil }
            return .roomTopic(topic, by: name(sender))
        case EventType.encryption:
            return .encryptionOn(by: name(sender))
        case EventType.member:
            guard let target = event.stateKey else { return nil }
            let membership = content["membership"]?.string
            let before = event.unsigned?["prev_content"]
            let was = before?["membership"]?.string
            let shownName = content["displayname"]?.string ?? name(target)
            switch membership {
            case "join":
                if was == "join" {
                    let old = before?["displayname"]?.string ?? ChatDigest.localpart(target)
                    guard let new = content["displayname"]?.string, new != old else { return nil }
                    return .renamedSelf(from: old, to: new)
                }
                return .joined(shownName)
            case "invite":
                return .invited(shownName, by: name(sender))
            case "leave":
                if sender != target { return .removed(before?["displayname"]?.string ?? name(target), by: name(sender)) }
                return .left(before?["displayname"]?.string ?? name(target))
            case "ban":
                return .banned(before?["displayname"]?.string ?? name(target), by: name(sender))
            default:
                return nil
            }
        default:
            return nil
        }
    }

    /// Самая поздняя отметка прочтения собеседников (время прочитанного события).
    static func othersReadTS(roomID: String, members: [(stateKey: String, sender: String?, content: JSONValue)],
                             me: String, store: Store) async throws -> Int? {
        var latest: Int?
        for member in members where member.stateKey != me && member.content["membership"]?.string == "join" {
            guard let receipted = try await store.receipt(roomID: roomID, userID: member.stateKey),
                  let seen = try await store.event(receipted) else { continue }
            latest = max(latest ?? 0, seen.originServerTS ?? 0)
        }
        return latest
    }
}
