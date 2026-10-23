// Нютаг. Язык интерфейса: бурятский, русский, английский. Выбирается при первом запуске и меняется в меню;
// системный язык не подходит: бурятского в iOS нет. Строки держим в коде одной таблицей, чтобы три перевода
// каждой фразы стояли рядом и не расходились.

import NyutagCore
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

    static let lettersKey = "nyutag.bxrLetters"

    /// Строка «ө ү һ» над полем ввода и замена «h», «y», «θ» внутри кириллицы. По умолчанию включена.
    var buryatLetters: Bool {
        didSet { UserDefaults.standard.set(buryatLetters, forKey: Self.lettersKey) }
    }

    init() {
        lang = UserDefaults.standard.string(forKey: Self.key).flatMap(Lang.init(rawValue:))
        buryatLetters = UserDefaults.standard.object(forKey: Self.lettersKey) as? Bool ?? true
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

    /// «Огненная Лошадь» / «Улаан морин» / «Fire Horse»: по-русски стихия согласуется с родом животного.
    func eastYear(_ year: EastYear) -> String {
        let animal = Self.animals[year.animal]
        let feminine = [0, 5, 6, 7, 8, 10, 11].contains(year.animal)
        let element = feminine ? Self.elementsFeminine[year.element] : Self.elements[year.element]
        return "\(self(element)) \(self(animal))"
    }

    private static let elements = [
        Phrase(bxr: "Хүхэ", ru: "Деревянный", en: "Wood"), Phrase(bxr: "Улаан", ru: "Огненный", en: "Fire"),
        Phrase(bxr: "Шара", ru: "Земляной", en: "Earth"), Phrase(bxr: "Сагаан", ru: "Металлический", en: "Metal"),
        Phrase(bxr: "Хара", ru: "Водяной", en: "Water"),
    ]
    private static let elementsFeminine = [
        Phrase(bxr: "Хүхэ", ru: "Деревянная", en: "Wood"), Phrase(bxr: "Улаан", ru: "Огненная", en: "Fire"),
        Phrase(bxr: "Шара", ru: "Земляная", en: "Earth"), Phrase(bxr: "Сагаан", ru: "Металлическая", en: "Metal"),
        Phrase(bxr: "Хара", ru: "Водяная", en: "Water"),
    ]
    private static let animals = [
        Phrase(bxr: "хулгана", ru: "Крыса", en: "Rat"), Phrase(bxr: "үхэр", ru: "Бык", en: "Ox"),
        Phrase(bxr: "бар", ru: "Тигр", en: "Tiger"), Phrase(bxr: "туулай", ru: "Кролик", en: "Rabbit"),
        Phrase(bxr: "луу", ru: "Дракон", en: "Dragon"), Phrase(bxr: "могой", ru: "Змея", en: "Snake"),
        Phrase(bxr: "морин", ru: "Лошадь", en: "Horse"), Phrase(bxr: "хонин", ru: "Овца", en: "Sheep"),
        Phrase(bxr: "бишэн", ru: "Обезьяна", en: "Monkey"), Phrase(bxr: "тахяа", ru: "Петух", en: "Rooster"),
        Phrase(bxr: "нохой", ru: "Собака", en: "Dog"), Phrase(bxr: "гахай", ru: "Свинья", en: "Pig"),
    ]
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
    static let emptyChat = Phrase(bxr: "Хоосон хөөрэлдөөн", ru: "Пустой чат", en: "Empty chat")
    static let you = Phrase(bxr: "Та", ru: "Вы", en: "You")
    static let invited = Phrase(bxr: "Танда урилга", ru: "Вас приглашают", en: "You're invited")
    static let newMessage = Phrase(bxr: "Шэнэ бэшэг", ru: "Новое сообщение", en: "New message")
    static let noMessages = Phrase(bxr: "Бэшэг үшөө үгы", ru: "Сообщений пока нет", en: "No messages yet")
    static let image = Phrase(bxr: "Зураг", ru: "Фото", en: "Photo")
    static let video = Phrase(bxr: "Видео", ru: "Видео", en: "Video")
    static let audio = Phrase(bxr: "Дуун бэшэг", ru: "Голосовое", en: "Voice message")
    static let voiceRecord = Phrase(bxr: "Дуун бэшэг бэшэхэ", ru: "Записать голосовое", en: "Record voice message")
    static let voiceCancel = Phrase(bxr: "Болюулха", ru: "Отменить запись", en: "Cancel recording")
    static let voiceNoMic = Phrase(bxr: "Микрофон хаалттай. Тохиргоодо нээгыт.", ru: "Нет доступа к микрофону. Разрешите его в Настройках.", en: "No microphone access. Allow it in Settings.")
    static let file = Phrase(bxr: "Файл", ru: "Файл", en: "File")
    static let location = Phrase(bxr: "Байра", ru: "Место", en: "Location")
    static let sticker = Phrase(bxr: "Наалта", ru: "Стикер", en: "Sticker")
    static let stickers = Phrase(bxr: "Наалтанууд", ru: "Стикеры", en: "Stickers")
    static let stickerMine = Phrase(bxr: "Минии наалтанууд", ru: "Мои стикеры", en: "My stickers")
    static let stickerAdd = Phrase(bxr: "Зурагһаа нэмэхэ", ru: "Добавить из галереи", en: "Add from gallery")
    static let stickerNone = Phrase(bxr: "Наалта үшөө үгы. Зурагһаа нэмэгты али хөөрэлдөөнһөө абагты.",
                                    ru: "Стикеров пока нет. Добавьте картинку из галереи или сохраните стикер из чата.",
                                    en: "No stickers yet. Add a picture from the gallery or save a sticker from a chat.")
    static let stickerSave = Phrase(bxr: "Минии наалтануудта", ru: "В мои стикеры", en: "Save to my stickers")
    static let stickerRemove = Phrase(bxr: "Минии наалтануудһаа хаяха", ru: "Убрать из моих", en: "Remove from mine")
    static let news = Phrase(bxr: "Нютагай һонинууд", ru: "Новости Нютага", en: "Nyutag news")
    static let newsEmpty = Phrase(bxr: "Һонин үгы", ru: "Пока новостей нет", en: "No news yet")
    static let newsFrom = Phrase(bxr: "Нютаг хэгшэдһээ", ru: "От команды Нютага", en: "From the Nyutag team")
    static let searchChats = Phrase(bxr: "Хөөрэлдөөн соо хайха", ru: "Поиск по чатам", en: "Search chats")
    static let searchMessages = Phrase(bxr: "Мэдээсэлнүүд", ru: "Сообщения", en: "Messages")
    static let searchNothing = Phrase(bxr: "Юумэ олдобогүй", ru: "Ничего не нашлось", en: "Nothing found")
    static let stickerSoyombo = Phrase(bxr: "Соёмбо", ru: "Соёмбо", en: "Soyombo")
    static let stickerFailed = Phrase(bxr: "Наалта нэмэгдэбэгүй", ru: "Стикер не добавился", en: "Couldn't add the sticker")
    static let poll = Phrase(bxr: "Һанал асуулга", ru: "Опрос", en: "Poll")
    static let call = Phrase(bxr: "Дуудалга", ru: "Звонок", en: "Call")
    static let yesterday = Phrase(bxr: "Үсэгэлдэр", ru: "Вчера", en: "Yesterday")

    static let language = Phrase(bxr: "Хэлэн", ru: "Язык", en: "Language")
    static let calendar = Phrase(bxr: "Хуанли", ru: "Календарь", en: "Calendar")
    static let sagaalgan = Phrase(bxr: "Сагаалган", ru: "Сагаалган", en: "Sagaalgan")
    static let sagaalganLeft = Phrase(bxr: "Үлэһэн үдэр: {1}", ru: "Осталось дней: {1}", en: "Days left: {1}")
    static let sagaalganToday = Phrase(bxr: "Мүнөөдэр Сагаалган. Сагаан һараар!", ru: "Сегодня Сагаалган. Сагаан һараар!",
                                       en: "Sagaalgan is today. Sagaan haraar!")
    static let eastYearOf = Phrase(bxr: "Жэл: {1}", ru: "Год по восточному календарю: {1}", en: "Eastern year: {1}")
    static let sagaalganYears = Phrase(bxr: "Сагаалган жэл бүри", ru: "Сагаалган по годам", en: "Sagaalgan by year")
    static let zurkhaiToday = Phrase(bxr: "Мүнөөдэр зурхайгаар", ru: "Сегодня по зурхаю", en: "Today by zurkhai")
    static let lunarDay = Phrase(bxr: "Сарын {1} хоног", ru: "{1}-е лунные сутки", en: "Lunar day {1}")
    static let haircut = Phrase(bxr: "Үһэ абахуу", ru: "Стрижка", en: "Haircut")
    static let favorable = Phrase(bxr: "Һайн", ru: "Благоприятно", en: "Favorable")
    static let unfavorable = Phrase(bxr: "Муу", ru: "Неблагоприятно", en: "Unfavorable")
    static let zurkhaiSource = Phrase(bxr: "Пхугпын ёһоор тоолоо. Мэдээн «Зурхай» программаһаа.",
                                      ru: "Расчёт по системе Пхугпа, данные нашего приложения «Зурхай».",
                                      en: "Phugpa system, data from our Zurkhai app.")
    static let buryatLetters = Phrase(bxr: "Буряад үсэгүүд", ru: "Бурятские буквы", en: "Buryat letters")
    static let buryatLettersHint = Phrase(bxr: "Бэшэхэдэ «ө ү һ» товшуурнууд. Латин h, y, θ кирилл үгэ соо өөрөө һэлгэгдэнэ.",
                                          ru: "Кнопки «ө ү һ» над полем ввода. Латинские h, y, θ внутри русского слова сами станут бурятскими буквами.",
                                          en: "Buttons «ө ү һ» above the message field. Latin h, y, θ inside a Cyrillic word turn into Buryat letters.")
    static let advanced = Phrase(bxr: "Нэмэлтэ", ru: "Дополнительно", en: "Advanced")
    static let signOut = Phrase(bxr: "Гараха", ru: "Выйти", en: "Sign out")
    static let signOutAsk = Phrase(bxr: "Энэ түхеэрэлгэ дээрэ аккаунтһаа гарахадаа итгэлтэй гүт?",
                                   ru: "Выйти из аккаунта на этом устройстве?",
                                   en: "Sign out on this device?")
    static let cancel = Phrase(bxr: "Болюулха", ru: "Отмена", en: "Cancel")
    static let done = Phrase(bxr: "Бэлэн", ru: "Готово", en: "Done")

    // Удаление аккаунта (App Store 5.1.1(v)); бурятский не сверен с носителем
    static let deleteAccount = Phrase(bxr: "Аккаунт усадхаха", ru: "Удалить аккаунт", en: "Delete account")
    static let deleteAccountLead = Phrase(
        bxr: "Аккаунт, профиль, шифрлэлгын түлхюурнүүд сервер дээрэ хэтэдээ усадхагдаха. Бусад хүнүүдэй чадуудта танай бэшэгүүд үлэхэ. Аккаунтые һөөргэнь бусааха аргагүй.",
        ru: "Аккаунт, профиль и ключи шифрования будут удалены на сервере навсегда. Ваши сообщения в чатах других людей останутся у них. Восстановить аккаунт нельзя.",
        en: "Your account, profile and encryption keys will be deleted from the server for good. Messages you sent to other people stay with them. This cannot be undone.")
    static let deleteAccountPassword = Phrase(bxr: "Баталхын тула нюуса үгэеэ оруулагты",
                                              ru: "Введите пароль, чтобы подтвердить", en: "Enter your password to confirm")
    static let deleteAccountFailed = Phrase(bxr: "Аккаунт усадхагдабагүй. Нюуса үгэеэ болон холбоогоо шалгагты.",
                                            ru: "Не удалось удалить аккаунт. Проверьте пароль и связь.",
                                            en: "Could not delete the account. Check the password and the connection.")

    // Пересылка; бурятский не сверен с носителем
    static let forward = Phrase(bxr: "Дамжуулха", ru: "Переслать", en: "Forward")
    static let forwarded = Phrase(bxr: "Дамжуулагдаһан", ru: "Переслано", en: "Forwarded")
    static let forwardFailed = Phrase(bxr: "Дамжуулагдабагүй. Холбоогоо шалгагты.",
                                      ru: "Не удалось переслать. Проверьте связь.",
                                      en: "Could not forward. Check the connection.")

    // Устройства, где открыт аккаунт; бурятский не сверен с носителем
    static let devices = Phrase(bxr: "Төхеөрөмжэнүүд", ru: "Устройства", en: "Devices")
    static let devicesLead = Phrase(bxr: "Аккаунт эдэ төхеөрөмжэнүүд дээрэ нээгдэһэн. Танихагүй төхеөрөмжэһөө гараха.",
                                    ru: "Здесь аккаунт открыт сейчас. Незнакомое устройство можно отключить.",
                                    en: "Your account is signed in on these devices. Sign out any you don't recognize.")
    static let thisDevice = Phrase(bxr: "Энэ төхеөрөмжэ", ru: "Это устройство", en: "This device")
    static let unnamedDevice = Phrase(bxr: "Нэрэгүй төхеөрөмжэ", ru: "Устройство без имени", en: "Unnamed device")
    static let lastSeen = Phrase(bxr: "Һүүлшын орохо: {1}", ru: "Последний вход: {1}", en: "Last seen: {1}")
    static let renameDevice = Phrase(bxr: "Нэрэ һэлгэхэ", ru: "Переименовать", en: "Rename")
    static let signOutDevice = Phrase(bxr: "Энэ төхеөрөмжэһөө гараха", ru: "Выйти на этом устройстве", en: "Sign out on this device")
    static let signOutDeviceLead = Phrase(
        bxr: "Тэрэ төхеөрөмжэ дээрэ аккаунт хаагдаха, шэнэ бэшэгүүд тэндэ ерэхэеэ болихо.",
        ru: "На том устройстве аккаунт закроется, и новые сообщения туда приходить перестанут.",
        en: "The account will be closed on that device and new messages will stop arriving there.")
    static let devicesFailed = Phrase(bxr: "Болобогүй. Нюуса үгэеэ болон холбоогоо шалгагты.",
                                      ru: "Не получилось. Проверьте пароль и связь.",
                                      en: "That didn't work. Check the password and the connection.")

    // Блокировка и жалоба (App Store 1.2); бурятский не сверен с носителем
    static let block = Phrase(bxr: "Хориглохо", ru: "Заблокировать", en: "Block")
    static let unblock = Phrase(bxr: "Хоригыень болюулха", ru: "Разблокировать", en: "Unblock")
    static let blocked = Phrase(bxr: "Хориглогдоһон", ru: "Заблокирован", en: "Blocked")
    static let blockAsk = Phrase(bxr: "Энэ хүниие хориглохо гүт? Тэрэнэй бэшэгүүд таанадта ерэхэеэ болихо.",
                                 ru: "Заблокировать этого человека? Его сообщения перестанут приходить.",
                                 en: "Block this person? Their messages will stop reaching you.")
    static let reportAction = Phrase(bxr: "Гомдол бэшэхэ", ru: "Пожаловаться", en: "Report")
    static let reportTitle = Phrase(bxr: "Бэшэг тухай гомдол", ru: "Жалоба на сообщение", en: "Report message")
    static let reportLead = Phrase(bxr: "Юун буруу бэ гэжэ бэшэгты. Гомдолые Нютагай захиргаан абаха.",
                                   ru: "Опишите, что не так. Жалобу получит администратор Нютага.",
                                   en: "Tell us what is wrong. The Nyutag administrator will receive the report.")
    static let reportReason = Phrase(bxr: "Шалтагаан", ru: "Причина", en: "Reason")
    static let reportAndBlock = Phrase(bxr: "Гомдол бэшээд хориглохо", ru: "Пожаловаться и заблокировать",
                                       en: "Report and block")
    static let reportSent = Phrase(bxr: "Гомдол эльгээгдээ", ru: "Жалоба отправлена", en: "Report sent")

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
    static let photoAction = Phrase(bxr: "Зураг, видео", ru: "Фото или видео", en: "Photo or video")
    static let videoTooBig = Phrase(bxr: "Видео хэтэрхэй томо: 25 МБ хүрэтэр", ru: "Видео не влезло: до 25 МБ после сжатия", en: "Video is too big: up to 25 MB after compression")
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
    static let viewOnceAction = Phrase(bxr: "Нэгэ удаа харах", ru: "Исчезающее: один просмотр", en: "View once")
    static let viewOnceSent = Phrase(bxr: "Нэгэ удаа харах зураг", ru: "Исчезающее фото", en: "View-once photo")
    static let viewOnceReceived = Phrase(bxr: "Нэгэ удаа харах зураг. Нээхын тула дарагты",
                                         ru: "Исчезающее фото. Нажмите, чтобы открыть", en: "View-once photo. Tap to open")
    static let viewOnceOpened = Phrase(bxr: "Хараһан", ru: "Просмотрено", en: "Opened")
    static let scheduleAction = Phrase(bxr: "Һүүлдэ эльгээхэ", ru: "Отправить позже", en: "Send later")
    static let scheduleTitle = Phrase(bxr: "Һүүлдэ эльгээхэ бэшэгүүд", ru: "Отложенные сообщения", en: "Scheduled messages")
    static let scheduleHint = Phrase(
        bxr: "Бэшэг шэлэгдэһэн сагта эльгээгдэхэ. Нютаг хаагдаһан байгаад, iOS һэргээгээгүй һаань, Нютаг нээхые һануулга ерэхэ.",
        ru: "Сообщение уйдёт в выбранное время. Если Нютаг закрыт и iOS его не разбудит, придёт напоминание открыть приложение.",
        en: "The message will be sent at the chosen time. If Nyutag is closed and iOS doesn't wake it, you'll get a reminder to open the app.")
    static let scheduleAt = Phrase(bxr: "{1} эльгээгдэхэ", ru: "Отправится {1}", en: "Sends {1}")
    static let scheduleBanner = Phrase(bxr: "Һүүлдэ эльгээхэ бэшэг: {1}", ru: "Отложенных сообщений: {1}", en: "Scheduled messages: {1}")
    static let scheduleSendNow = Phrase(bxr: "Мүнөө эльгээхэ", ru: "Отправить сейчас", en: "Send now")
    static let schedulePast = Phrase(bxr: "Ерээдүйн саг шэлэгты.", ru: "Выберите время в будущем.", en: "Pick a time in the future.")
    static let savedMessages = Phrase(bxr: "Хадагалһан", ru: "Избранное", en: "Saved messages")
    static let savedMessagesTopic = Phrase(bxr: "Өөртөө тэмдэглэл, холбоос, файлнууд", ru: "Заметки, ссылки и файлы для себя",
                                           en: "Notes, links and files for yourself")
    static let inviteFriend = Phrase(bxr: "Нүхэрөө уриха", ru: "Пригласить друга", en: "Invite a friend")
    static let inviteCreating = Phrase(bxr: "Урилга бэлдэжэ байна…", ru: "Создаю приглашение…", en: "Creating an invitation…")
    static let inviteFailed = Phrase(bxr: "Урилга бүтээжэ шадабагүйбди. Һүүлдэ оролдогты.",
                                     ru: "Не удалось создать приглашение. Попробуйте позже.",
                                     en: "Could not create an invitation. Try again later.")
    static let inviteLimit = Phrase(bxr: "Урилгын хизаар: 10 хэрэглэгдээгүй код, хоногто 20 хүрэтэр.",
                                    ru: "Лимит приглашений: не больше 10 неиспользованных кодов и 20 в сутки.",
                                    en: "Invitation limit reached: at most 10 unused codes and 20 a day.")
    /// {1} — код, {2} — ссылка.
    static let inviteShareText = Phrase(
        bxr: "Нютаг — манай мессенджер руу урижа байнаб: {2}\nУрилгын код: {1} (нэгэ удаа, 7 хоног хүсэнтэй). Нютаг табяад, «Бүртхүүлхэ» гэжэ дарагты.",
        ru: "Приглашаю тебя в Нютаг, наш мессенджер: {2}\nКод приглашения: {1} (сработает один раз, действует 7 дней). Установи Нютаг и нажми «Зарегистрироваться».",
        en: "Join me on Nyutag, our messenger: {2}\nInvitation code: {1} (works once, for 7 days). Install Nyutag and tap “Sign up”.")
    static let inviteHint = Phrase(bxr: "Код нэгэ удаа хүсэнтэй, 7 хоног хүсэнтэй. QR харуулагты али холбоос эльгээгты.",
                                   ru: "Код сработает один раз и действует 7 дней. Покажите QR или отправьте ссылку.",
                                   en: "The code works once and lasts 7 days. Show the QR or send the link.")
    static let inviteShare = Phrase(bxr: "Хубаалдаха", ru: "Поделиться", en: "Share")
    static let inviteNew = Phrase(bxr: "Шэнэ код", ru: "Новый код", en: "New code")
    static let inviteMine = Phrase(bxr: "Минии урилганууд", ru: "Мои приглашения", en: "My invitations")
    static let inviteUsedBy = Phrase(bxr: "{1} хэрэглэбэ", ru: "Использовал {1}", en: "Used by {1}")
    static let inviteValidTill = Phrase(bxr: "{1} хүрэтэр хүсэнтэй", ru: "Действует до {1}", en: "Valid until {1}")
    static let inviteExpired = Phrase(bxr: "Хугацаань дууһаа", ru: "Срок истёк", en: "Expired")
    static let inviteRevoke = Phrase(bxr: "Болюулха", ru: "Отозвать", en: "Revoke")
    static let profile = Phrase(bxr: "Профиль", ru: "Профиль", en: "Profile")
    static let profileAbout = Phrase(bxr: "Өөрын тухай", ru: "О себе", en: "About")
    static let avatarChange = Phrase(bxr: "Фото һэлгэхэ", ru: "Сменить фото", en: "Change photo")
    static let avatarRemove = Phrase(bxr: "Фото усадхаха", ru: "Убрать фото", en: "Remove photo")
    static let avatarFailed = Phrase(bxr: "Фото табигдабагүй. Дахин оролдыт.", ru: "Фото не загрузилось. Попробуйте ещё раз.",
                                     en: "The photo wasn't uploaded. Try again.")
    static let profileAboutPlaceholder = Phrase(bxr: "Өөрынгөө тухай хэдэн үгэ", ru: "Пару слов о себе",
                                                en: "A few words about yourself")
    static let profileToonto = Phrase(bxr: "Тоонто нютаг", ru: "Тоонто нютаг", en: "Toonto nyutag (homeland)")
    static let profileToontoPlaceholder = Phrase(bxr: "Таанай уг хаанахиб", ru: "Откуда ваш род", en: "Where your family is from")
    static let profileUg = Phrase(bxr: "Уг гарбал", ru: "Род (уг гарбал)", en: "Clan (ug garbal)")
    static let profileUgPlaceholder = Phrase(bxr: "Жэшээнь, Хуасай", ru: "Например, Хуасай", en: "For example, Khuasai")
    static let profileEastYear = Phrase(bxr: "Түрэһэн жэл", ru: "Год по восточному календарю", en: "Year by the Eastern calendar")
    static let profileEastYearHint = Phrase(
        bxr: "Зүүн зүгэй жэл Сагаалганһаа эхилдэг (январь–февраль). Сагаалганай урда түрэһэн хүн урдахи жэлээ шэлэгты.",
        ru: "Восточный год начинается с Сагаалгана (январь–февраль). Если вы родились до Сагаалгана, выберите предыдущий год.",
        en: "The Eastern year starts at Sagaalgan (January–February). If you were born before Sagaalgan, pick the previous year.")
    static let profileEastYearNone = Phrase(bxr: "Заагдаагүй", ru: "Не указан", en: "Not set")
    static let profileSaveFailed = Phrase(bxr: "Хадагалжа шадабагүйбди. Дахин оролдогты.",
                                          ru: "Не удалось сохранить. Попробуйте ещё раз.", en: "Could not save. Try again.")
    static let forgotPassword = Phrase(bxr: "Нюуса үгэеэ мартаа гүт?", ru: "Забыли пароль?", en: "Forgot password?")
    static let resetTitle = Phrase(bxr: "Нюуса үгэ шэнэлхэ", ru: "Сброс пароля", en: "Reset password")
    static let resetLead = Phrase(bxr: "Нютагай аккаунтдаа холбоотой e-mail хаягаа оруулагты. Тэндэ код эльгээхэбди.",
                                  ru: "Введите почту, к которой привязан аккаунт Нютага. Пришлём на неё код.",
                                  en: "Enter the email linked to your Nyutag account. We'll send a code there.")
    static let resetSend = Phrase(bxr: "Код эльгээхэ", ru: "Прислать код", en: "Send code")
    static let resetNewPassword = Phrase(bxr: "Шэнэ нюуса үгэ, 8 тэмдэгһээ доошо бэшэ", ru: "Новый пароль, не короче 8 символов",
                                         en: "New password, at least 8 characters")
    static let resetSubmit = Phrase(bxr: "Хадагалаад орохо", ru: "Сохранить и войти", en: "Save and sign in")
    static let resetUnknown = Phrase(
        bxr: "Энэ хаягта Нютагай аккаунт холбоотой бэшэ. Хаягаа шалгагты: ондоо почтоор бүртхүүлһэн байжа магад.",
        ru: "К этой почте не привязан ни один аккаунт Нютага. Проверьте адрес: возможно, вы регистрировались с другой почтой.",
        en: "No Nyutag account is linked to this email. Check the address: you may have signed up with a different one.")
    static let donate = Phrase(bxr: "Нютагта туһалха", ru: "Поддержать Нютаг", en: "Support Nyutag")
    static let donateBody = Phrase(
        bxr: "Нютагые бага студи хэнэ. Бэшэлгэ, дуудалга, мэдүүлгэ ябуулдаг серверүүдэй түлөө бидэ өөһэдөө түлэнэбди, мүнөө алдагдалтайгаар хүдэлнэбди. Нютагта реклама үгы, байхашьегүй. Хэрэгтэй гэжэ һанабал, туһалыт: ямаршье мүнгэн серверүүдтэ ошохо.",
        ru: "Нютаг делает маленькая студия. Серверы, через которые идут переписка, звонки и уведомления, мы оплачиваем сами и пока работаем в минус. Рекламы в Нютаге нет и не будет. Если он вам нужен, поддержите его: любая сумма идёт на серверы.",
        en: "Nyutag is made by a tiny studio. We pay for the servers that carry your chats, calls and notifications ourselves, and so far we run at a loss. There are no ads in Nyutag and there never will be. If you find it useful, support it: every bit goes to the servers.")
    static let donateThanks = Phrase(bxr: "Һайн даа! Таны туһаламжа Нютагай серверүүдые хүдэлгэнэ.",
                                     ru: "Спасибо! Ваша поддержка держит серверы Нютага.",
                                     en: "Thank you! Your support keeps Nyutag's servers running.")
    static let donateUnavailable = Phrase(bxr: "Магазинтай холбоо үгы. Һүүлдэ дахин оролдыт.",
                                          ru: "Не удалось связаться с магазином. Попробуйте позже.",
                                          en: "Could not reach the store. Please try again later.")
    static let myPhone = Phrase(bxr: "Минии дугаар", ru: "Мой номер", en: "My phone number")
    static let myPhonePlaceholder = Phrase(bxr: "+7 900 000-00-00", ru: "+7 900 000-00-00", en: "+1 555 000 0000")
    static let myPhoneChange = Phrase(bxr: "Шэнэ дугаар", ru: "Новый номер", en: "New number")
    static let myPhoneHint = Phrase(bxr: "Дугаартайш танилнууд Нютагта шамайе олохо. Бусадта дугаар харагдахагүй.",
                                    ru: "Знакомые, у которых есть ваш номер, найдут вас в Нютаге. Другим номер не виден.",
                                    en: "People who have your number will find you in Nyutag. Nobody else sees it.")
    static let myPhoneSet = Phrase(bxr: "Дугаар заагдаа. Һэлгэхэ гэбэл шэнэ дугаар оруулагты.",
                                   ru: "Номер указан. Чтобы сменить, введите новый.",
                                   en: "Your number is set. Enter a new one to change it.")
    static let phoneNotInNyutag = Phrase(bxr: "Энэ дугаар Нютагта үгы. Уряал эльгээхэ", ru: "Этого номера нет в Нютаге. Пригласить",
                                         en: "This number isn't on Nyutag. Invite")
    static let wallpaper = Phrase(bxr: "Хөөрэлдөөнэй дэбисхэр", ru: "Обои чатов", en: "Chat wallpaper")
    static let wallpaperForChat = Phrase(bxr: "Энэ хөөрэлдөөнэй дэбисхэр", ru: "Обои этого чата", en: "Wallpaper for this chat")
    static let wallpaperAsEverywhere = Phrase(bxr: "Бусадтал адли", ru: "Как во всех", en: "Same as all")
    static let wallpaperMilk = Phrase(bxr: "Һүн", ru: "Молоко", en: "Milk")
    static let wallpaperBaikal = Phrase(bxr: "Байгал", ru: "Байкал", en: "Baikal")
    static let wallpaperSteppe = Phrase(bxr: "Тала", ru: "Степь", en: "Steppe")
    static let wallpaperDawn = Phrase(bxr: "Үүр", ru: "Заря", en: "Dawn")
    static let wallpaperNight = Phrase(bxr: "Һүни", ru: "Ночь", en: "Night")
    static let wallpaperPhoto = Phrase(bxr: "Фото", ru: "Фото", en: "Photo")
    static let wallpaperPickPhoto = Phrase(bxr: "Галерейһээ фото абаха", ru: "Выбрать фото из галереи", en: "Choose a photo")
    static let wallpaperPhotoFailed = Phrase(bxr: "Энэ фото уншагдаагүй.", ru: "Не удалось открыть это фото.",
                                             en: "Couldn't open this photo.")
    static let wallpaperSampleTheirs = Phrase(bxr: "Сайн байна! Юу шэнэб?", ru: "Сайн байна! Как дела?", en: "Hi! How are you?")
    static let wallpaperSampleMine = Phrase(bxr: "Сайн, сайн. Ши юу хэжэ байнаш?", ru: "Хорошо! А ты чем занят?",
                                            en: "Good! What are you up to?")
    static let scheduledReminder = Phrase(bxr: "Һүүлдэ эльгээхэ бэшэг эльгээгдээгүй", ru: "Отложенное сообщение ещё не ушло",
                                          en: "A scheduled message hasn't been sent yet")
    static let autoDelete = Phrase(bxr: "Бэшэгүүдые автоматаар усадхаха", ru: "Автоудаление сообщений",
                                   en: "Auto-delete messages")
    static let autoDeleteHint = Phrase(bxr: "Энэ чат соохи шэнэ бэшэгүүд шэлэгдэһэн сагай һүүлээр бүгэдэдэ усадхагдаха.",
                                       ru: "Новые сообщения в этом чате удалятся у всех через выбранное время.",
                                       en: "New messages in this chat will be deleted for everyone after the chosen time.")
    static let autoDeleteOff = Phrase(bxr: "Үгы", ru: "Выкл.", en: "Off")
    static let autoDeleteDay = Phrase(bxr: "1 үдэр", ru: "1 день", en: "1 day")
    static let autoDeleteWeek = Phrase(bxr: "7 хоног", ru: "1 неделя", en: "1 week")
    static let autoDeleteMonth = Phrase(bxr: "1 һара", ru: "1 месяц", en: "1 month")
    static let autoDeleteError = Phrase(bxr: "Таймер хубилгажа шадабагүй. Дахин оролдогты.",
                                        ru: "Не удалось изменить таймер. Попробуйте ещё раз.", en: "Couldn’t change the timer. Try again.")

    static let communitiesSearch = Phrase(bxr: "Оршон бэдэрхэ", ru: "Поиск сообществ", en: "Search communities")
    static let communitiesMine = Phrase(bxr: "Минии оршонууд", ru: "Мои сообщества", en: "My communities")
    static let communitiesAll = Phrase(bxr: "Бүхы оршонууд", ru: "Все сообщества", en: "All communities")
    static let communitiesEmpty = Phrase(bxr: "Оршон үшөө үгы. Түрүүшынхиеэ байгуулагты!",
                                         ru: "Сообществ пока нет. Создайте первое!", en: "No communities yet. Create the first one!")
    static let communitiesFailed = Phrase(bxr: "Оршонууд ачаалагдабагүй. Доошоо татажа дахин оролдогты.",
                                          ru: "Сообщества не загрузились. Потяните вниз, чтобы повторить.",
                                          en: "Couldn't load communities. Pull down to try again.")
    static let communityOpen = Phrase(bxr: "Нээлттэй", ru: "Открытое", en: "Open")
    static let communityOpenHint = Phrase(bxr: "Хэн бүхэн бэдэржэ олоод, ороод болохо.",
                                          ru: "Любой найдёт его в поиске и сможет вступить.",
                                          en: "Anyone can find it in search and join.")
    static let communityClosed = Phrase(bxr: "Хаалттай", ru: "Закрытое", en: "Closed")
    static let communityClosedHint = Phrase(bxr: "Хэн бүхэн бэдэржэ олоод, гуйлта эльгээхэ. Шэнэ гэшүүдые админ зүбшөөнэ.",
                                            ru: "Любой найдёт его в поиске и подаст заявку. Новых участников одобряет админ.",
                                            en: "Anyone can find it in search and send a request. An admin approves new members.")
    static let communityClosedBadge = Phrase(bxr: "Хаалттай · гуйлтаар", ru: "Закрытое · по заявке", en: "Closed · by request")
    static let communityMembers = Phrase(bxr: "Гэшүүд: {1}", ru: "Участников: {1}", en: "Members: {1}")
    static let communityGroups = Phrase(bxr: "Бүлэгүүд", ru: "Группы", en: "Groups")
    static let communityNoGroups = Phrase(bxr: "Эндэ бүлэг үшөө үгы", ru: "Здесь пока нет групп", en: "No groups yet")
    static let communityNoGroupsHint = Phrase(bxr: "Удангүй админ нэмэхэ. Тэрэ зуура нүхэдөө уригты.",
                                              ru: "Скоро их добавит админ. А пока позовите друзей.",
                                              en: "The admin will add them soon. Meanwhile, invite friends.")
    static let communityGroupsHint = Phrase(bxr: "Бүлэг бүри — оршоной хөөрэлдөөн. Нээгээд, доодо талада бэшэгты.",
                                            ru: "Каждая группа — это чат сообщества. Откройте её и пишите внизу.",
                                            en: "Each group is a community chat. Open one and type at the bottom.")
    static let communityJoinToWrite = Phrase(bxr: "Бэшэхэ, гэшүүдые харахын тула оршондо орогты.",
                                             ru: "Чтобы писать и видеть участников, вступите в сообщество.",
                                             en: "Join the community to write and see its members.")
    static let communityWrite = Phrase(bxr: "Бэшэхэ", ru: "Написать", en: "Message")
    static let communityGeneralChat = Phrase(bxr: "Ниитэ хөөрэлдөөн", ru: "Общий чат", en: "General chat")
    static let communityPeople = Phrase(bxr: "Гэшүүд · {1}", ru: "Участники · {1}", en: "Members · {1}")
    static let communityShowAll = Phrase(bxr: "Бүгэдыень харуулха", ru: "Показать всех", en: "Show all")
    static let communityAdmin = Phrase(bxr: "админ", ru: "админ", en: "admin")
    static let communityJoin = Phrase(bxr: "Оршондо орохо", ru: "Вступить", en: "Join")
    static let communityRequest = Phrase(bxr: "Гуйлта эльгээхэ", ru: "Подать заявку", en: "Request to join")
    static let communityRequested = Phrase(bxr: "Гуйлта эльгээгдэбэ. Админ зүбшөөхэдэ, оршон эндэ гараха.",
                                           ru: "Заявка отправлена. Когда админ одобрит, сообщество появится здесь.",
                                           en: "Request sent. Once an admin approves it, the community shows up here.")
    static let communityInvite = Phrase(bxr: "Уриха", ru: "Пригласить", en: "Invite")
    static let communityInviteText = Phrase(bxr: "Нютаг соо «{1}» оршондо орогты: «Оршонууд» таб. Татажа абаха: https://nyutag.chat",
                                            ru: "Вступайте в сообщество «{1}» в Нютаге: вкладка «Сообщества». Скачать: https://nyutag.chat",
                                            en: "Join the community “{1}” on Nyutag: it's in the Communities tab. Get the app: https://nyutag.chat")
    static let communityLeave = Phrase(bxr: "Гараха", ru: "Выйти", en: "Leave")
    static let communityLeaveAsk = Phrase(bxr: "Оршонһоо гараха гүт? Бүлэгүүд соо үлэхэт.",
                                          ru: "Выйти из сообщества? В его группах вы останетесь.",
                                          en: "Leave the community? You'll stay in its groups.")
    static let communityNew = Phrase(bxr: "Шэнэ оршон", ru: "Новое сообщество", en: "New community")
    static let communityName = Phrase(bxr: "Нэрэ", ru: "Название", en: "Name")
    static let communityAbout = Phrase(bxr: "Юун тухай", ru: "О чём сообщество", en: "What it's about")
    static let communityCreate = Phrase(bxr: "Байгуулха", ru: "Создать", en: "Create")
    static let communityGroupNew = Phrase(bxr: "Шэнэ бүлэг", ru: "Новая группа", en: "New group")
    static let communityFailed = Phrase(bxr: "Бүтэбэгүй. Дахин оролдогты.", ru: "Не получилось. Попробуйте ещё раз.",
                                        en: "That didn't work. Try again.")

    // Группы из списка чатов
    static let groupNew = Phrase(bxr: "Шэнэ бүлэг", ru: "Новая группа", en: "New group")
    static let groupName = Phrase(bxr: "Бүлэгэй нэрэ", ru: "Название группы", en: "Group name")
    static let groupWho = Phrase(bxr: "Хэниие уриха", ru: "Кого позвать", en: "Who to invite")
    static let groupWhoHint = Phrase(bxr: "Эндэ танай хөөрэлдэдэг хүнүүд. Бусадые «Контактнууд» соо олоорой.",
                                     ru: "Здесь те, с кем у вас уже есть переписка. Остальных найдите в «Контактах».",
                                     en: "People you already chat with. Find others in Contacts.")
    static let groupNobody = Phrase(bxr: "Уриха хүн үшөө үгы", ru: "Пока некого позвать", en: "No one to invite yet")
    static let groupCreate = Phrase(bxr: "Байгуулха", ru: "Создать", en: "Create")
    static let groupFailed = Phrase(bxr: "Бүлэг байгуулагдабагүй. Дахин оролдогты.", ru: "Группа не создалась. Попробуйте ещё раз.",
                                    en: "The group wasn't created. Try again.")
    static let groupInfo = Phrase(bxr: "Бүлэг тухай", ru: "О группе", en: "About group")
    static let groupMembers = Phrase(bxr: "Гэшүүд", ru: "Участники", en: "Members")
    static let groupAdd = Phrase(bxr: "Гэшүүдые нэмэхэ", ru: "Добавить участников", en: "Add members")
    static let groupAddFailed = Phrase(bxr: "Хүн бүхэн уригдабагүй. Дахин оролдогты.", ru: "Позвать удалось не всех. Попробуйте ещё раз.",
                                       en: "Some people couldn't be invited. Try again.")
    static let chatLeave = Phrase(bxr: "Чатһаа гараха", ru: "Покинуть чат", en: "Leave chat")
    static let chatLeaveHint = Phrase(bxr: "Чат хэрэглэдэг жагсаалтһаа үгы болохо. Һөөргөө орохын тула шэнэ урилга хэрэгтэй.",
                                      ru: "Чат исчезнет из списка. Вернуться можно по новому приглашению.",
                                      en: "The chat will disappear from the list. You can return with a new invitation.")
    static let chatLeaveFailed = Phrase(bxr: "Гарагдабагүй. Дахин оролдогты.", ru: "Выйти не удалось. Попробуйте ещё раз.",
                                        en: "Couldn't leave. Try again.")
    static let mute = Phrase(bxr: "Абяагүй", ru: "Без звука", en: "Mute")
    static let unmute = Phrase(bxr: "Абяатай", ru: "Со звуком", en: "Unmute")
    static let muted = Phrase(bxr: "Абяагүй чат", ru: "Чат без звука", en: "Muted")
}
