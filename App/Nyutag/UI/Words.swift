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
    static let noAccount = Phrase(bxr: "Аккаунт үгы гү?", ru: "Нет аккаунта?", en: "No account yet?")
    static let wrongPassword = Phrase(bxr: "Нэрэ али нюуса үгэ буруу", ru: "Неверное имя или пароль",
                                      en: "Wrong name or password")
    static let tooOften = Phrase(bxr: "Хэтэ олон оролдолго. Нэгэ минута хүлеэгээд, дахин оролдогты.",
                                 ru: "Слишком много попыток. Подождите минуту и попробуйте снова.",
                                 en: "Too many attempts. Wait a minute and try again.")
    static let noNetwork = Phrase(bxr: "Сервертэй холбоо үгы. Дахин оролдогты.", ru: "Нет связи с сервером. Попробуйте ещё раз.",
                                  en: "Can't reach the server. Try again.")

    // Регистрация
    static let signUp = Phrase(bxr: "Бүртхүүлхэ", ru: "Зарегистрироваться", en: "Sign up")
    static let signUpTitle = Phrase(bxr: "Шэнэ аккаунт", ru: "Новый аккаунт", en: "New account")
    static let signUpLead = Phrase(bxr: "Нэгэ хуудаһа бүглөөд, e-mail дээрээ ерэһэн кодоо оруулагты",
                                   ru: "Заполните одну форму, потом введите код из письма",
                                   en: "Fill in one form, then enter the code from the email")
    static let name = Phrase(bxr: "Нэрэ", ru: "Имя", en: "Name")
    static let phone = Phrase(bxr: "Утаһан", ru: "Телефон", en: "Phone")
    static let email = Phrase(bxr: "E-mail", ru: "Почта", en: "Email")
    static let newPassword = Phrase(bxr: "Нюуса үгэ, 8 тэмдэгһээ дээшэ", ru: "Пароль, от 8 знаков",
                                    en: "Password, 8+ characters")
    static let inviteCode = Phrase(bxr: "Урилгын код", ru: "Код приглашения", en: "Invite code")
    static let nickLabel = Phrase(bxr: "Нютаг дахи хаяг", ru: "Адрес в Нютаге", en: "Your Nyutag address")
    static let nickTaken = Phrase(bxr: "Энэ хаяг эзэлэгдэһэн", ru: "Этот адрес занят", en: "This address is taken")
    static let nickRules = Phrase(bxr: "Латин үсэг, тоо болон . _ -", ru: "Латиница, цифры и . _ -",
                                  en: "Latin letters, digits and . _ -")
    static let getCode = Phrase(bxr: "Код абаха", ru: "Получить код", en: "Get the code")
    static let sendingCode = Phrase(bxr: "Эльгээжэ байна…", ru: "Отправляем…", en: "Sending…")
    static let codeTitle = Phrase(bxr: "Кодоо оруулагты", ru: "Введите код", en: "Enter the code")
    static let codeSent = Phrase(bxr: "{1} хаяг руу 6 тоотой код эльгээбэбди",
                                 ru: "Мы отправили код из 6 цифр на {1}",
                                 en: "We sent a 6-digit code to {1}")
    static let codeSpam = Phrase(bxr: "Бэшэг үгы һаа, «Спам» хубааха шалгагты",
                                 ru: "Если письма нет, загляните в «Спам»",
                                 en: "No email? Check your spam folder")
    static let resend = Phrase(bxr: "Дахин эльгээхэ", ru: "Отправить ещё раз", en: "Send again")
    static let resendIn = Phrase(bxr: "Дахин эльгээхэ: {1} сек", ru: "Отправить ещё раз через {1} с",
                                 en: "Send again in {1}s")
    static let changeDetails = Phrase(bxr: "Мэдээсэлээ заһаха", ru: "Изменить данные", en: "Change details")
    static let creatingAccount = Phrase(bxr: "Аккаунт бии болгожо байна…", ru: "Создаём аккаунт…",
                                        en: "Creating your account…")
    static let phoneTaken = Phrase(bxr: "Энэ утаһанай дугаараар аккаунт бии", ru: "На этот номер уже есть аккаунт",
                                   en: "There's already an account with this number")
    static let emailTaken = Phrase(bxr: "Энэ e-mail хаягаар аккаунт бии", ru: "На эту почту уже есть аккаунт",
                                   en: "There's already an account with this email")
    static let badPhone = Phrase(bxr: "Утаһанай дугаараа шалгагты", ru: "Проверьте номер телефона",
                                 en: "Check the phone number")
    static let badEmail = Phrase(bxr: "E-mail хаягаа шалгагты", ru: "Проверьте адрес почты", en: "Check the email address")
    static let weakPassword = Phrase(bxr: "Нюуса үгэ 8 тэмдэгһээ богони", ru: "Пароль короче 8 знаков",
                                     en: "The password is shorter than 8 characters")
    static let badInvite = Phrase(bxr: "Урилгын код олдоогүй", ru: "Код приглашения не найден", en: "Invite code not found")
    static let inviteUsed = Phrase(bxr: "Урилгын код хэрэглэгдэһэн али хугацаань дууһаһан",
                                   ru: "Код приглашения уже использован или истёк",
                                   en: "This invite code is used or expired")
    static let wrongCode = Phrase(bxr: "Код таарахагүй байна", ru: "Код не подходит", en: "Wrong code")
    static let codeExpired = Phrase(bxr: "Кодой хугацаа дууһаба. Шэнэ код абагты.", ru: "Код устарел. Запросите новый.",
                                    en: "The code has expired. Request a new one.")
    static let tooManyTries = Phrase(bxr: "Хэтэ олон оролдолго. Шэнэ код абагты.",
                                     ru: "Слишком много попыток. Запросите новый код.",
                                     en: "Too many attempts. Request a new code.")
    static let mailFailed = Phrase(bxr: "Бэшэг эльгээгдэбэгүй. Һүүлдэ дахин оролдогты.",
                                   ru: "Письмо не ушло. Попробуйте чуть позже.",
                                   en: "The email didn't go out. Try again a bit later.")

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

    // Старая история под прежним ключом
    static let historyLockedTitle = Phrase(bxr: "Хуушан бэшэгүүд хаалтатай", ru: "Старые сообщения закрыты",
                                           en: "Older messages are locked")
    static let historyLockedLead = Phrase(bxr: "Урдань хадагалһан һэргээлгын түлхюурээ оруулагты",
                                          ru: "Введите ключ восстановления, который вы сохраняли раньше",
                                          en: "Enter the recovery key you saved earlier")
    static let historyKeyExplain = Phrase(
        bxr: "Энэ аккаунт дээрэ бэшэгүүд урдань түлхюураар хаагдаһан байна. Нэгэ дахин оруулаад, саашадаа нюуса үгөөрөө оронот.",
        ru: "Раньше переписку этого аккаунта запирал отдельный ключ. Введите его один раз, дальше на любом устройстве хватит пароля.",
        en: "This account's messages were locked with a separate key. Enter it once; after that your password is enough on any device.")
    static let historyKeyExplainNoPassword = Phrase(
        bxr: "Ключ оруулбал, хуушан бэшэгүүд энэ түхеэрэлгэ дээрэ нээгдэхэ.",
        ru: "Ключ откроет старые сообщения на этом устройстве.",
        en: "The key opens older messages on this device.")
    static let recoveryKey = Phrase(bxr: "Һэргээлгын түлхюур", ru: "Ключ восстановления", en: "Recovery key")
    static let paste = Phrase(bxr: "Оруулха", ru: "Вставить", en: "Paste")
    static let openHistory = Phrase(bxr: "Бэшэгүүдые нээхэ", ru: "Открыть историю", en: "Open history")
    static let openingHistory = Phrase(bxr: "Нээжэ байна…", ru: "Открываем…", en: "Opening…")
    static let wrongKey = Phrase(bxr: "Түлхюур таарахагүй байна. Үсэг бүриие шалгагты.",
                                 ru: "Ключ не подходит. Проверьте каждый знак.",
                                 en: "This key doesn't fit. Check every character.")
    static let historyOpened = Phrase(bxr: "Хуушан бэшэгүүд нээгдэбэ", ru: "Старые сообщения открыты",
                                      en: "Older messages are open")
    static let later = Phrase(bxr: "Һүүлдэ", ru: "Позже", en: "Later")

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
    static let editAction = Phrase(bxr: "Заһаха", ru: "Изменить", en: "Edit")
    static let deleteAction = Phrase(bxr: "Усадхаха", ru: "Удалить", en: "Delete")
    static let deleteAsk = Phrase(bxr: "Бэшэгые бүгэдэдэ усадхаха гү?", ru: "Удалить сообщение у всех?",
                                  en: "Delete this message for everyone?")
    static let editing = Phrase(bxr: "Заһалга", ru: "Изменение", en: "Editing")
    static let typingNow = Phrase(bxr: "бэшэжэ байна…", ru: "печатает…", en: "typing…")
    static let typingName = Phrase(bxr: "{1} бэшэжэ байна…", ru: "{1} печатает…", en: "{1} is typing…")
    static let typingMany = Phrase(bxr: "{1} болон {2} хүн бэшэжэ байна…", ru: "{1} и ещё {2} печатают…",
                                   en: "{1} and {2} more are typing…")
    static let attach = Phrase(bxr: "Хабсаргаха", ru: "Прикрепить", en: "Attach")
    static let photoAction = Phrase(bxr: "Зураг", ru: "Фото", en: "Photo")
    static let fileAction = Phrase(bxr: "Файл", ru: "Файл", en: "File")
    static let cantDo = Phrase(bxr: "Бүтэбэгүй. Холбоогоо шалгагты.", ru: "Не получилось. Проверьте связь.",
                               en: "That didn't work. Check your connection.")

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

    // Контакты
    static let inNyutag = Phrase(bxr: "Нютагта", ru: "В Нютаге", en: "On Nyutag")
    static let callToNyutag = Phrase(bxr: "Нютагта уриха", ru: "Позвать в Нютаг", en: "Invite to Nyutag")
    static let inviteShort = Phrase(bxr: "Уриха", ru: "Позвать", en: "Invite")
    static let foundByName = Phrase(bxr: "Нэрээр олдобо", ru: "Нашлись по имени", en: "Found by name")
    static let searchPeople = Phrase(bxr: "Нэрэ, ник гү, али дугаар", ru: "Имя, ник или номер", en: "Name, username or number")
    static let nobodyFound = Phrase(bxr: "Хэншье олдоогүй", ru: "Никого не нашли", en: "Nobody found")
    static let peopleEmpty = Phrase(bxr: "Хөөрэлдэһэн хүнүүд эндэ гараха", ru: "Здесь появятся люди, с которыми вы переписываетесь",
                                    en: "People you talk to will show up here")
    static let bookTitle = Phrase(bxr: "Танилнуудаа Нютагһаа олохо", ru: "Найти знакомых в Нютаге",
                                  en: "Find people you know on Nyutag")
    static let bookLead = Phrase(bxr: "Утаһанай дугаарнуудые Нютагай сервертэ тааруулжа харана. Дугаарнууд хадагалагдахагүй.",
                                 ru: "Номера из телефонной книги сверим с сервером Нютага. Сервер их не сохраняет.",
                                 en: "We check the numbers in your phone book against the Nyutag server. It does not keep them.")
    static let bookAllow = Phrase(bxr: "Контактнуудые харуулха", ru: "Открыть доступ к контактам", en: "Allow access to contacts")
    static let bookDenied = Phrase(bxr: "Контактнууд хаалтатай. Тааруулгануудта нээжэ болоно.",
                                   ru: "Доступ к контактам закрыт. Его можно открыть в настройках.",
                                   en: "Contacts access is off. You can turn it on in Settings.")
    static let openSettings = Phrase(bxr: "Тааруулганууд", ru: "Открыть настройки", en: "Open Settings")
    static let inviteText = Phrase(bxr: "Нютагта бэшэлдэе! Татажа абаха: https://nyutag.chat",
                                   ru: "Давай переписываться в Нютаге! Скачать: https://nyutag.chat",
                                   en: "Let's chat on Nyutag! Get it here: https://nyutag.chat")
    static let cantOpenChat = Phrase(bxr: "Хөөрэлдөөн нээгдэбэгүй. Дахин оролдогты.", ru: "Не получилось открыть чат. Попробуйте ещё раз.",
                                     en: "Couldn't open the chat. Try again.")

    // Подтверждение входа с другого устройства
    static let otherDeviceTitle = Phrase(bxr: "Оролтоо баталагты", ru: "Подтвердите вход", en: "Confirm this sign-in")
    static let otherDeviceLead = Phrase(bxr: "Урдань ороһон утаһан гү, компьютер дээрэ Нютаг нээгты",
                                        ru: "Откройте Нютаг там, где вы уже вошли", en: "Open Nyutag where you're already signed in")
    static let otherDeviceWait = Phrase(
        bxr: "Нүгөө төхөөрэмжэ дээрээ Нютаг нээгты. Тэндэ асуудал гараха, тэрэниие баталагты.",
        ru: "Откройте Нютаг на другом устройстве. Там появится запрос, подтвердите его.",
        en: "Open Nyutag on your other device. A request will appear there; confirm it.")
    static let newSignInTitle = Phrase(bxr: "Шэнэ оролто", ru: "Новый вход", en: "New sign-in")
    static let newSignInAsk = Phrase(
        bxr: "«{1}» таны бэшэгүүдые харахаар асууна. Та өөрөө оролдоо һаа, баталжа, эмодзинуудые тааруулагты.",
        ru: "«{1}» просит доступ к вашей переписке. Если это вы, подтвердите и сверьте эмодзи.",
        en: "“{1}” is asking for access to your chats. If this is you, confirm and compare the emoji.")
    static let anotherDevice = Phrase(bxr: "Нүгөө төхөөрэмжэ", ru: "Другое устройство", en: "Another device")
    static let itsMe = Phrase(bxr: "Энэ би", ru: "Это я", en: "It's me")
    static let notMe = Phrase(bxr: "Энэ би бэшэ", ru: "Это не я", en: "Not me")
    static let matchingKeys = Phrase(bxr: "Түлхюурнүүдые тааруулжа байна…", ru: "Сверяем ключи…", en: "Checking keys…")
    static let compareEmoji = Phrase(bxr: "Нүгөө дэлгэсэ дээрэхитэй тааруулагты", ru: "Сравните с экраном другого устройства",
                                     en: "Compare with the screen of your other device")
    static let emojiMatch = Phrase(bxr: "Таарана", ru: "Совпадают", en: "They match")
    static let emojiDiffer = Phrase(bxr: "Таарахагүй", ru: "Не совпадают", en: "They don't match")
    static let waitOtherSide = Phrase(bxr: "Нүгөө төхөөрэмжын баталгые хүлеэнэбди…", ru: "Ждём подтверждения на другом устройстве…",
                                      en: "Waiting for your other device…")
    static let signInConfirmed = Phrase(bxr: "Оролто баталагдаба", ru: "Вход подтверждён", en: "Sign-in confirmed")
    static let keysComing = Phrase(bxr: "Бэшэгүүдэй түлхюурнүүдые абажа байна…", ru: "Получаем ключи переписки…",
                                   en: "Getting your chat keys…")
    static let checkStopped = Phrase(bxr: "Шалгалта зогсобо", ru: "Проверка остановлена", en: "Check stopped")
    static let emojiMismatch = Phrase(bxr: "Эмодзинууд таарабагүй, оролто баталагдабагүй",
                                      ru: "Эмодзи не совпали, вход не подтверждён", en: "The emoji didn't match. Sign-in not confirmed.")
    static let noOtherDevice = Phrase(bxr: "Нютагтай нүгөө төхөөрэмжэ олдобогүй", ru: "Других устройств с Нютагом не нашли",
                                      en: "No other devices with Nyutag found")
    static let confirmFromDevice = Phrase(bxr: "Нүгөө төхөөрэмжөөр баталха", ru: "Подтвердить с другого устройства",
                                          en: "Confirm from another device")
    static let pin = Phrase(bxr: "Бэхилхэ", ru: "Закрепить", en: "Pin")
    static let unpin = Phrase(bxr: "Бэхилэлгые болюулха", ru: "Открепить", en: "Unpin")
    static let pinned = Phrase(bxr: "Бэхилэгдэһэн", ru: "Закреплён", en: "Pinned")
    static let pinLimit = Phrase(bxr: "5-һаа олон чат бэхилхэ аргагүй", ru: "Закрепить можно не больше 5 чатов",
                                 en: "You can pin up to 5 chats")
    static let folderAll = Phrase(bxr: "Бүгэдэ", ru: "Все", en: "All")
    static let folderAdd = Phrase(bxr: "Папка руу нэмэхэ", ru: "Добавить в папку", en: "Add to folder")
    static let folderNew = Phrase(bxr: "Шэнэ папка", ru: "Новая папка", en: "New folder")
    static let folderName = Phrase(bxr: "Папкын нэрэ", ru: "Название папки", en: "Folder name")
    static let folderRename = Phrase(bxr: "Папкын нэрые һэлгэхэ", ru: "Переименовать папку", en: "Rename folder")
    static let folderDelete = Phrase(bxr: "Папка усадхаха", ru: "Удалить папку", en: "Delete folder")
    static let folderDeleteHint = Phrase(bxr: "Чатууд жагсаалтада үлэхэ, зүгөөр папка усадхагдаха.",
                                         ru: "Чаты останутся в списке, удалится только папка.",
                                         en: "Chats stay in the list, only the folder is removed.")
    static let folderEmpty = Phrase(bxr: "Папкада үшөө чат үгы. Чат дээрэ удаан дарижа, «Папка руу нэмэхэ» шэлэгты.",
                                    ru: "В папке пока нет чатов. Зажмите чат и выберите «Добавить в папку».",
                                    en: "No chats in this folder yet. Long-press a chat and choose “Add to folder”.")
    static let save = Phrase(bxr: "Хадагалха", ru: "Сохранить", en: "Save")
    static let close = Phrase(bxr: "Хааха", ru: "Закрыть", en: "Close")
}
