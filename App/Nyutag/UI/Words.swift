// Нютаг. Язык интерфейса: бурятский, русский, английский. Выбирается при первом запуске и меняется в меню;
// системный язык не подходит: бурятского в iOS нет. Строки держим в коде одной таблицей, чтобы три перевода
// каждой фразы стояли рядом и не расходились.

import SwiftUI

enum Lang: String, CaseIterable, Identifiable {
    case bxr, ru, en
    var id: String { rawValue }

    /// Название языка на нём самом.
    var ownName: String {
        switch self {
        case .bxr: "Буряад хэлэн"
        case .ru: "Русский"
        case .en: "English"
        }
    }

    var locale: Locale { Locale(identifier: self == .bxr ? "ru" : rawValue) }
}

@MainActor @Observable
final class Words {
    static let key = "nyutag.lang"

    /// `nil` — язык ещё не выбран: показываем экран выбора.
    private(set) var lang: Lang?

    init() {
        lang = UserDefaults.standard.string(forKey: Self.key).flatMap(Lang.init(rawValue:))
    }

    func choose(_ lang: Lang) {
        self.lang = lang
        UserDefaults.standard.set(lang.rawValue, forKey: Self.key)
    }

    func callAsFunction(_ phrase: Phrase) -> String {
        switch lang ?? .ru {
        case .bxr: phrase.bxr
        case .ru: phrase.ru
        case .en: phrase.en
        }
    }
}

struct Phrase {
    let bxr: String
    let ru: String
    let en: String
}

extension Phrase {
    static let pickLanguage = Phrase(bxr: "Хэлэн шэлэгты", ru: "Выберите язык", en: "Choose a language")
    static let languageLater = Phrase(bxr: "Хэлэниие һүүлдэ менюдэ һэлгэжэ болохо",
                                      ru: "Язык можно сменить потом в меню",
                                      en: "You can change it later in the menu")
    static let welcome = Phrase(bxr: "Сайн байна!", ru: "Сайн байна!", en: "Sain baina!")
    static let signInLead = Phrase(bxr: "Нэрэ, утаһан али e-mail болон нюуса үгөө оруулагты",
                                   ru: "Войдите по имени, телефону или почте",
                                   en: "Sign in with your name, phone or email")
    static let identifier = Phrase(bxr: "Нэрэ, утаһан али e-mail", ru: "Имя, телефон или почта", en: "Name, phone or email")
    static let password = Phrase(bxr: "Нюуса үгэ", ru: "Пароль", en: "Password")
    static let signIn = Phrase(bxr: "Орохо", ru: "Войти", en: "Sign in")
    static let signingIn = Phrase(bxr: "Оржо байна…", ru: "Входим…", en: "Signing in…")
    static let noAccount = Phrase(bxr: "Аккаунт үгы гү? Урилгын код хэрэгтэй.",
                                  ru: "Нет аккаунта? Нужен код приглашения.",
                                  en: "No account? You need an invite code.")
    static let wrongPassword = Phrase(bxr: "Нэрэ али нюуса үгэ буруу", ru: "Неверное имя или пароль",
                                      en: "Wrong name or password")
    static let tooOften = Phrase(bxr: "Хэтэ олон оролдолго. Нэгэ минута хүлеэгээд, дахин оролдогты.",
                                 ru: "Слишком много попыток. Подождите минуту и попробуйте снова.",
                                 en: "Too many attempts. Wait a minute and try again.")
    static let noNetwork = Phrase(bxr: "Сервертэй холбоо үгы. Дахин оролдогты.", ru: "Нет связи с сервером. Попробуйте ещё раз.",
                                  en: "Can't reach the server. Try again.")

    static let chats = Phrase(bxr: "Хөөрэлдөөнүүд", ru: "Чаты", en: "Chats")
    static let contacts = Phrase(bxr: "Контактнууд", ru: "Контакты", en: "Contacts")
    static let communities = Phrase(bxr: "Оршонууд", ru: "Сообщества", en: "Communities")
    static let chatsEmpty = Phrase(bxr: "Эндэ таны чатнууд гараха", ru: "Здесь появятся ваши чаты",
                                   en: "Your chats will appear here")
    static let soon = Phrase(bxr: "Удангүй", ru: "Скоро", en: "Coming soon")
    static let emptyChat = Phrase(bxr: "Хоосон хөөрэлдөөн", ru: "Пустой чат", en: "Empty chat")
    static let you = Phrase(bxr: "Та", ru: "Вы", en: "You")
    static let invited = Phrase(bxr: "Танда урилга", ru: "Вас приглашают", en: "You're invited")
    static let newMessage = Phrase(bxr: "Шэнэ бэшэг", ru: "Новое сообщение", en: "New message")
    static let noMessages = Phrase(bxr: "Бэшэг үшөө үгы", ru: "Сообщений пока нет", en: "No messages yet")
    static let image = Phrase(bxr: "Зураг", ru: "Фото", en: "Photo")
    static let video = Phrase(bxr: "Видео", ru: "Видео", en: "Video")
    static let audio = Phrase(bxr: "Дуун бэшэг", ru: "Голосовое", en: "Voice message")
    static let file = Phrase(bxr: "Файл", ru: "Файл", en: "File")
    static let location = Phrase(bxr: "Байра", ru: "Место", en: "Location")
    static let sticker = Phrase(bxr: "Наалта", ru: "Стикер", en: "Sticker")
    static let poll = Phrase(bxr: "Һанал асуулга", ru: "Опрос", en: "Poll")
    static let call = Phrase(bxr: "Дуудалга", ru: "Звонок", en: "Call")
    static let yesterday = Phrase(bxr: "Үсэгэлдэр", ru: "Вчера", en: "Yesterday")

    static let language = Phrase(bxr: "Хэлэн", ru: "Язык", en: "Language")
    static let advanced = Phrase(bxr: "Нэмэлтэ", ru: "Дополнительно", en: "Advanced")
    static let signOut = Phrase(bxr: "Гараха", ru: "Выйти", en: "Sign out")
    static let signOutAsk = Phrase(bxr: "Энэ түхеэрэлгэ дээрэ аккаунтһаа гарахадаа итгэлтэй гүт?",
                                   ru: "Выйти из аккаунта на этом устройстве?",
                                   en: "Sign out on this device?")
    static let cancel = Phrase(bxr: "Болюулха", ru: "Отмена", en: "Cancel")
    static let done = Phrase(bxr: "Бэлэн", ru: "Готово", en: "Done")
}
