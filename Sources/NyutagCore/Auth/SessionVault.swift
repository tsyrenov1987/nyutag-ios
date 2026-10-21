// Нютаг. Где живёт вход: сессия (токен, устройство) — в связке ключей с общей группой доступа, чтобы её видело
// расширение уведомлений; база — в общем контейнере группы приложений, своя папка на каждый Matrix ID.
// Токен в связке доступен после первой разблокировки (пуш может прийти при заблокированном экране)
// и не уезжает в резервную копию на другое устройство.

import CryptoKit
import Foundation
import Security

public struct SessionVault: Sendable {
    public let service: String
    /// Группа доступа связки ключей (`<TeamID>.group.chat.nyutag.messenger`); `nil` — связка самого процесса.
    public let accessGroup: String?

    static let account = "active"

    public init(service: String = "chat.nyutag.session", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    /// Связка, общая у приложения и расширения уведомлений (команда 643UT34CF8, см. *.entitlements).
    public static let shared = SessionVault(accessGroup: SharedShelf.appGroup.isEmpty ? nil : "643UT34CF8." + SharedShelf.appGroup)

    public enum Failure: Error, Equatable {
        case keychain(OSStatus)
        case corrupt
    }

    public func save(_ session: Session) throws(Failure) {
        let data: Data
        do { data = try JSONEncoder().encode(session) } catch { throw .corrupt }
        let status = SecItemUpdate(query() as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query()
            item[kSecValueData] = data
            item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            try check(SecItemAdd(item as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    /// Сохранённая сессия или `nil`, если входа не было. Испорченная запись — ошибка, а не тихий выход.
    public func load() throws(Failure) -> Session? {
        var item = query()
        item[kSecReturnData] = true
        item[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let session = try? JSONDecoder().decode(Session.self, from: data) else {
            throw .corrupt
        }
        return session
    }

    public func erase() throws(Failure) {
        let status = SecItemDelete(query() as CFDictionary)
        guard status == errSecItemNotFound else { return try check(status) }
    }

    private func query() -> [CFString: Any] {
        var query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                      kSecAttrAccount: Self.account]
        if let accessGroup { query[kSecAttrAccessGroup] = accessGroup }
        #if os(iOS)
        query[kSecUseDataProtectionKeychain] = true
        #endif
        return query
    }

    private func check(_ status: OSStatus) throws(Failure) {
        guard status == errSecSuccess else { throw .keychain(status) }
    }
}

/// Раскладка файлов в общем контейнере: приложение и расширение открывают одну и ту же базу.
public struct SharedShelf: Sendable {
    /// Группа из Info.plist: у отладочной сборки «Нютаг β» своя, чтобы не делить базу с магазинным Нютагом.
    /// Пустая строка — сборка без группы (ручная подпись на iPhone): база и связка только у самого приложения.
    public static let appGroup = Bundle.main.object(forInfoDictionaryKey: "NyutagAppGroup") as? String
        ?? "group.chat.nyutag.messenger"

    /// Без группы: папка Application Support самого приложения, расширение уведомлений её не видит.
    public static func own() -> SharedShelf? {
        guard let url = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true) else { return nil }
        return SharedShelf(root: url)
    }

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Контейнер группы приложений; `nil`, если у процесса нет права на группу.
    public init?(appGroup: String) {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            return nil
        }
        root = url
    }

    /// Папка аккаунта: имя — хеш Matrix ID, чтобы в путях не светился логин.
    public func folder(for userID: String) -> URL {
        let digest = SHA256.hash(data: Data(userID.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        return root.appending(path: "accounts", directoryHint: .isDirectory).appending(path: digest, directoryHint: .isDirectory)
    }

    public func storeURL(for userID: String) -> URL {
        folder(for: userID).appending(path: "nyutag.sqlite")
    }

    /// База аккаунта; папка создаётся и исключается из резервной копии (ключи E2EE не должны уезжать в iCloud).
    public func openStore(for userID: String) throws -> Store {
        var folder = folder(for: userID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        return try Store(path: storeURL(for: userID).path(percentEncoded: false))
    }

    /// Выход: стираем базу аккаунта вместе с журналами WAL.
    public func wipe(userID: String) throws {
        let folder = folder(for: userID)
        guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else { return }
        try FileManager.default.removeItem(at: folder)
    }
}
