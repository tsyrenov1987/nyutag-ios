// Нютаг. Двери к ядру: обычные HTTPS-сайты на наших доменах, за которыми стоит ядро nyutag.chat.
// Клиент идёт к ядру по TLS насквозь (сертификат двери выдан публичным центром, доверие системное),
// узлы по дороге только передают байты. Дверь открывается заголовком с ключом из каталога; без него
// сайт отвечает 404, как любой чужой адрес. Здесь чистая логика: разбор каталога, гонка проб и память
// о последней удачной двери (её читает и расширение уведомлений). Сами пробы живут в приложении.

import Foundation

/// Дверь: схема, хост и порт, путь запроса подставляет клиент.
public struct Door: Sendable, Hashable, Codable {
    public let url: URL
    public let name: String

    /// Только `https` с хостом и без пути: иначе дверь не наша или адрес сломан.
    public init?(url: URL, name: String) {
        guard url.scheme == "https", let host = url.host(), !host.isEmpty,
              url.path().isEmpty || url.path() == "/", url.query() == nil else { return nil }
        self.url = url
        self.name = name
    }

    /// Строка каталога `https://host[:port]#имя`; без имени имя — хост.
    public init?(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("https://") else { return nil }
        let parts = trimmed.split(separator: "#", maxSplits: 1).map(String.init)
        guard let first = parts.first, var components = URLComponents(string: first) else { return nil }
        // Хвостовой «/» — тот же адрес: храним без него, чтобы двери сравнивались по адресу.
        if components.path == "/" { components.path = "" }
        guard let url = components.url, let host = url.host() else { return nil }
        self.init(url: url, name: parts.count > 1 && !parts[1].isEmpty ? parts[1] : host)
    }
}

/// Каталог из бандла: ключ и двери. Строки `kilvater://…` старого формата пропускаются.
public struct DoorCatalogue: Sendable, Equatable {
    public static let headerName = "X-Nyutag-Door"
    static let keyPrefix = "door-key "

    public let key: String
    public let doors: [Door]

    public init(key: String, doors: [Door]) {
        self.key = key
        self.doors = doors
    }

    /// Текст: строка `door-key <ключ>`, затем по двери на строку; пустые строки и `#…` — заметки.
    /// Без ключа или без дверей каталога нет.
    public init?(text: String) {
        var key: String?
        var doors: [Door] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix(Self.keyPrefix) {
                key = String(line.dropFirst(Self.keyPrefix.count)).trimmingCharacters(in: .whitespaces)
            } else if let door = Door(line: line) {
                doors.append(door)
            }
        }
        guard let key, !key.isEmpty, !doors.isEmpty else { return nil }
        self.init(key: key, doors: doors)
    }

    /// Двери из строк каталога сервера (`doors` в `/_nyutag/v1/catalogue`), непонятные строки пропускаются.
    public static func doors(from lines: [String]) -> [Door] {
        lines.compactMap { Door(line: $0) }
    }

    /// Объединение без повторов, порядок сохраняется: сначала `first`, затем новые из `second`.
    public static func merge(_ first: [Door], _ second: [Door]) -> [Door] {
        var seen = Set<URL>()
        return (first + second).filter { seen.insert($0.url).inserted }
    }
}

/// Память о дверях в общих настройках группы приложений: последняя удачная дверь с ключом (расширение
/// уведомлений ходит по ней, своей гонки у него нет) и двери, присланные сервером.
public enum DoorMemory {
    static let lastKey = "nyutag.door.last"
    static let keyKey = "nyutag.door.key"
    static let dynamicKey = "nyutag.door.dynamic"

    /// Настройки группы; без группы (ошибка подписи) — обычные, тогда расширение двери не увидит.
    public static var shared: UserDefaults {
        let group = SharedShelf.appGroup
        return group.isEmpty ? .standard : UserDefaults(suiteName: group) ?? .standard
    }

    /// Дверь хранится строкой каталога (адрес и имя): по ней DoorHub узнаёт свою дверь в каталоге.
    public static func remember(_ door: Door, key: String, in defaults: UserDefaults = shared) {
        defaults.set("\(door.url.absoluteString)#\(door.name)", forKey: lastKey)
        defaults.set(key, forKey: keyKey)
    }

    public static func recall(from defaults: UserDefaults = shared) -> (door: Door, key: String)? {
        guard let text = defaults.string(forKey: lastKey), let door = Door(line: text),
              let key = defaults.string(forKey: keyKey), !key.isEmpty else { return nil }
        return (door, key)
    }

    public static func rememberDynamic(_ doors: [Door], in defaults: UserDefaults = shared) {
        defaults.set(doors.map { "\($0.url.absoluteString)#\($0.name)" }, forKey: dynamicKey)
    }

    public static func recallDynamic(from defaults: UserDefaults = shared) -> [Door] {
        DoorCatalogue.doors(from: defaults.stringArray(forKey: dynamicKey) ?? [])
    }

    public static func forget(in defaults: UserDefaults = shared) {
        for key in [lastKey, keyKey, dynamicKey] { defaults.removeObject(forKey: key) }
    }
}

/// Гонка дверей: все пробуются разом, побеждает первая, за которой ответило ядро.
public enum DoorRace {
    /// Порядок проб: последняя удачная дверь первой, повторы убраны.
    public static func order(_ doors: [Door], preferred: Door?) -> [Door] {
        var ordered = DoorCatalogue.merge([], doors)
        if let preferred, let index = ordered.firstIndex(of: preferred) {
            ordered.remove(at: index)
            ordered.insert(preferred, at: 0)
        }
        return ordered
    }

    /// Предпочтительная дверь стартует первой, остальные — через `headStart`, если она ещё не ответила:
    /// знакомая живая дверь остаётся за человеком, а двери не дёргаются без нужды. Без предпочтения
    /// все стартуют сразу. `probe` отвечает, пустило ли ядро; проигравшие пробы снимаются.
    public static func run(_ doors: [Door], preferred: Door?, headStart: Duration,
                           probe: @escaping @Sendable (Door) async -> Bool) async -> Door? {
        let ordered = order(doors, preferred: preferred)
        guard !ordered.isEmpty else { return nil }
        let delayed = preferred != nil && ordered.first == preferred && headStart > .zero
        return await withTaskGroup(of: Door?.self) { group in
            for (index, door) in ordered.enumerated() {
                group.addTask {
                    if delayed, index > 0 {
                        try? await Task.sleep(for: headStart)
                        if Task.isCancelled { return nil }
                    }
                    return await probe(door) ? door : nil
                }
            }
            for await winner in group {
                if let winner {
                    group.cancelAll()
                    return winner
                }
            }
            return nil
        }
    }
}
