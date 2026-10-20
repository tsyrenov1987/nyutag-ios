import Foundation
@testable import NyutagCore
import Testing

/// Вход, хранение сессии в связке ключей, подъём при запуске и выход.
@Suite(.serialized) struct AccountKeeperTests {
    /// Тестовый бандл без приложения-хозяина на симуляторе iOS не имеет права на связку (-34018, errSecMissingEntitlement):
    /// там тесты связки выключены, на Маке и в приложении они идут.
    static let keychainReachable: Bool = {
        let probe = SessionVault(service: "chat.nyutag.test.probe.\(UUID().uuidString)")
        do { _ = try probe.load() } catch SessionVault.Failure.keychain(-34018) { return false } catch {}
        return true
    }()

    static let user = "@dorzho:nyutag.chat"

    /// Своя служба на тест: связка ключей общая у всех процессов пользователя.
    func scratch() throws -> (SessionVault, SharedShelf) {
        let vault = SessionVault(service: "chat.nyutag.test.\(UUID().uuidString)")
        let root = FileManager.default.temporaryDirectory.appending(path: "nyutag-shelf-\(UUID().uuidString)")
        return (vault, SharedShelf(root: root))
    }

    @Test(.enabled(if: keychainReachable, "нет права на связку ключей")) func vaultKeepsReplacesAndErases() throws {
        let (vault, _) = try scratch()
        defer { try? vault.erase() }
        #expect(try vault.load() == nil)
        let first = Session(userID: Self.user, deviceID: "D1", accessToken: "t1",
                            homeserver: URL(string: "https://core.nyutag.chat:6167")!)
        try vault.save(first)
        #expect(try vault.load() == first)
        let second = Session(userID: Self.user, deviceID: "D2", accessToken: "t2", homeserver: first.homeserver)
        try vault.save(second)
        #expect(try vault.load() == second)
        // Чужая служба запись не видит.
        #expect(try SessionVault(service: vault.service + ".other").load() == nil)
        try vault.erase()
        #expect(try vault.load() == nil)
        try vault.erase()
    }

    @Test func shelfFolderHidesUserID() throws {
        let (_, shelf) = try scratch()
        let folder = shelf.folder(for: Self.user)
        #expect(!folder.path().contains("dorzho"))
        #expect(folder != shelf.folder(for: "@other:nyutag.chat"))
        #expect(folder == shelf.folder(for: Self.user))
    }

    @Test(.enabled(if: keychainReachable, "нет права на связку ключей")) func signInRestoreSignOut() async throws {
        let server = FakeHomeserver()
        server.setPassword("секрет", user: Self.user)
        let (vault, shelf) = try scratch()
        defer { try? vault.erase(); try? FileManager.default.removeItem(at: shelf.root) }
        let keeper = AccountKeeper(vault: vault, shelf: shelf) { _, token in server.client(accessToken: token) }
        #expect(try keeper.restore() == nil)
        await #expect(throws: MatrixError.self) {
            try await keeper.signIn(homeserver: server.homeserver, user: "dorzho", password: "не тот", deviceName: "iPhone")
        }
        #expect(try vault.load() == nil)

        let account = try await keeper.signIn(homeserver: server.homeserver, user: "dorzho", password: "секрет",
                                              deviceName: "iPhone")
        #expect(account.session.userID == Self.user)
        try await account.store.setMeta("probe", "1")
        #expect(FileManager.default.fileExists(atPath: shelf.storeURL(for: Self.user).path(percentEncoded: false)))

        // Перезапуск: та же сессия и та же база, без похода в сеть.
        let restored = try #require(try keeper.restore())
        #expect(restored.session == account.session)
        #expect(try await restored.store.meta("probe") == "1")
        #expect(try await restored.client.whoAmI().userID == Self.user)

        try await keeper.signOut(restored)
        #expect(!server.isTokenValid(account.session.accessToken))
        #expect(try vault.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: shelf.folder(for: Self.user).path(percentEncoded: false)))
        #expect(try keeper.restore() == nil)
    }
}
