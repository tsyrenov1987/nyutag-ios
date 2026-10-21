// Нютаг. Жизненный цикл входа: войти и запомнить, поднять сохранённое при запуске, выйти и стереть следы.
// Приложение и расширение уведомлений пользуются одним и тем же хранителем, отличаются только путём в сеть.

import Foundation

/// Вошедший аккаунт: всё, что нужно синку, шифрованию и пушам.
public struct SignedInAccount: Sendable {
    public let session: Session
    public let client: MatrixClient
    public let store: Store
}

public struct AccountKeeper: Sendable {
    public let vault: SessionVault
    public let shelf: SharedShelf
    /// Клиент под адрес сервера и токен: дверь к ядру (или прямой путь) задаёт вызывающий.
    let makeClient: @Sendable (_ homeserver: URL, _ accessToken: String?) -> MatrixClient

    public init(vault: SessionVault, shelf: SharedShelf,
                makeClient: @escaping @Sendable (_ homeserver: URL, _ accessToken: String?) -> MatrixClient) {
        self.vault = vault
        self.shelf = shelf
        self.makeClient = makeClient
    }

    /// Вход по паролю. Сессия сохраняется до открытия базы: если база не откроется, повторный запуск поднимет
    /// уже выданное устройство, а не заведёт новое.
    public func signIn(homeserver: URL, user: String, password: String,
                       deviceName: String) async throws -> SignedInAccount {
        let client = makeClient(homeserver, nil)
        let session = try await client.login(user: user, password: password, deviceDisplayName: deviceName)
        try vault.save(session)
        return try SignedInAccount(session: session, client: client, store: shelf.openStore(for: session.userID))
    }

    /// Сохранённый вход или `nil`. Токен не проверяем по сети: запуск без связи должен показать переписку из базы.
    public func restore() throws -> SignedInAccount? {
        guard let session = try vault.load() else { return nil }
        return try SignedInAccount(session: session, client: makeClient(session.homeserver, session.accessToken),
                                   store: shelf.openStore(for: session.userID))
    }

    /// Выход. Токен отзываем на сервере по возможности; локально стираем всегда, даже без связи.
    public func signOut(_ account: SignedInAccount) async throws {
        try? await account.client.logout()
        try vault.erase()
        try shelf.wipe(userID: account.session.userID)
    }

    /// Сервер ответил, что токен больше не действует (вышли с другого устройства): стираем без запроса.
    public func forget(userID: String) throws {
        try vault.erase()
        try shelf.wipe(userID: userID)
    }
}
