// Нютаг. Хранитель входа в приложении: сессия в общей связке, база в контейнере группы (их же читает
// расширение уведомлений), а каждый клиент к ядру идёт только через туннель.

import Foundation
import NyutagCore

extension AccountKeeper {
    /// `nil`, если у сборки нет права на группу приложений (ошибка подписи, а не состояние пользователя).
    static func app(tunnel: TunnelHub = .shared) -> AccountKeeper? {
        let group = SharedShelf.appGroup
        guard let shelf = group.isEmpty ? SharedShelf.own() : SharedShelf(appGroup: group) else { return nil }
        return AccountKeeper(vault: .shared, shelf: shelf) { homeserver, accessToken in
            tunnel.makeClient(homeserver: homeserver, accessToken: accessToken)
        }
    }
}
