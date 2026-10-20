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

    /// Фраза с подстановками `{1}`, `{2}`: имена в служебных плашках.
    func callAsFunction(_ phrase: Phrase, _ values: String...) -> String {
        var text = self(phrase)
        for (index, value) in values.enumerated() { text = text.replacingOccurrences(of: "{\(index + 1)}", with: value) }
        return text
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

    // Экран чата
    static let messageField = Phrase(bxr: "Бэшэг", ru: "Сообщение", en: "Message")
    static let send = Phrase(bxr: "Эльгээхэ", ru: "Отправить", en: "Send")
    static let reply = Phrase(bxr: "Харюусаха", ru: "Ответить", en: "Reply")
    static let copy = Phrase(bxr: "Хуулаха", ru: "Копировать", en: "Copy")
    static let edited = Phrase(bxr: "заһагдаһан", ru: "изм.", en: "edited")
    static let deleted = Phrase(bxr: "Бэшэг усадхагдаһан", ru: "Сообщение удалено", en: "Message deleted")
    static let waitingKey = Phrase(bxr: "Түлхюур хүлеэгдэнэ", ru: "Ждём ключ от отправителя", en: "Waiting for the key")
    static let notSent = Phrase(bxr: "Ошоогүй. Дахин эльгээхын тула дарагты", ru: "Не отправлено. Нажмите, чтобы повторить",
                                en: "Not sent. Tap to retry")
    static let today = Phrase(bxr: "Мүнөөдэр", ru: "Сегодня", en: "Today")

    // Служебные плашки
    static let noticeCreated = Phrase(bxr: "Хөөрэлдөөн бии болобо", ru: "Чат создан", en: "Chat created")
    static let noticeJoined = Phrase(bxr: "Шэнэ гэшүүн: {1}", ru: "Новый участник: {1}", en: "{1} joined")
    static let noticeLeft = Phrase(bxr: "Хөөрэлдөөнһөө гараба: {1}", ru: "Вышли из чата: {1}", en: "{1} left")
    static let noticeInvited = Phrase(bxr: "Урилга: {1}", ru: "Приглашение: {1}", en: "{2} invited {1}")
    static let noticeRemoved = Phrase(bxr: "Хөөрэлдөөнһөө гаргагдаба: {1}", ru: "Удалены из чата: {1}", en: "{2} removed {1}")
    static let noticeBanned = Phrase(bxr: "Хаагдаба: {1}", ru: "Заблокированы: {1}", en: "{2} banned {1}")
    static let noticeRenamed = Phrase(bxr: "{1} → {2}", ru: "{1} теперь {2}", en: "{1} is now {2}")
    static let noticeRoomName = Phrase(bxr: "Шэнэ нэрэ: {1}", ru: "Новое название: {1}", en: "New name: {1}")
    static let noticeRoomPhoto = Phrase(bxr: "Хөөрэлдөөнэй шэнэ зураг", ru: "Новое фото чата", en: "New chat photo")
    static let noticeTopic = Phrase(bxr: "Тайлбари: {1}", ru: "Описание: {1}", en: "Description: {1}")
    static let noticeEncrypted = Phrase(bxr: "Бэшэгүүд нюуса шифрээр хамгаалагдана", ru: "Сообщения защищены сквозным шифрованием",
                                        en: "Messages are end-to-end encrypted")
}
