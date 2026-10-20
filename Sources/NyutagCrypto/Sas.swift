// Нютаг. Короткая строка подтверждения (SAS, `m.sas.v1`): общий секрет X25519 двух устройств даёт семь эмодзи
// или три числа, которые люди сверяют глазами, и ключи MAC (`hkdf-hmac-sha256.v2`) для обмена подписями ключей.

import Foundation

/// Одна сторона SAS до обмена ключами: свежая пара X25519 на каждую проверку.
public struct Sas: Sendable {
    let keyPair: Curve25519KeyPair

    public init() { keyPair = Curve25519KeyPair() }

    public init(privateKey: Data) throws(CryptoError) { keyPair = try Curve25519KeyPair(rawRepresentation: privateKey) }

    public var publicKeyBase64: String { keyPair.publicKeyBase64 }

    public func establish(theirPublicKey: String) throws(CryptoError) -> EstablishedSas {
        EstablishedSas(secret: try keyPair.sharedSecret(with: try Base64.decode(theirPublicKey)))
    }
}

/// SAS после обмена ключами.
public struct EstablishedSas: Sendable {
    let secret: Data

    public func bytes(info: String, count: Int = 6) -> Data {
        Hash.hkdfSHA256(ikm: secret, salt: Data(), info: Data(info.utf8), outputByteCount: count)
    }

    /// Семь номеров эмодзи: первые 42 бита по 6.
    public func emojiIndices(info: String) -> [Int] {
        let value = bytes(info: info).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return (0..<7).map { Int(value >> (42 - 6 * UInt64($0)) & 0x3F) }
    }

    /// Три числа 1000…9191: первые 39 бит по 13.
    public func decimals(info: String) -> [Int] {
        let value = bytes(info: info).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return (0..<3).map { Int(value >> (35 - 13 * UInt64($0)) & 0x1FFF) + 1000 }
    }

    /// MAC строки ключом, выведенным из общего секрета по `info`.
    public func calculateMac(_ input: String, info: String) -> String {
        let key = Hash.hkdfSHA256(ikm: secret, salt: Data(), info: Data(info.utf8), outputByteCount: 32)
        return Base64.encodeUnpadded(Hash.hmacSHA256(key: key, data: Data(input.utf8)))
    }
}

/// Таблица эмодзи из спецификации Matrix (`sas-emoji.json`) с её же русскими названиями.
public enum SasEmoji {
    public static let table: [(emoji: String, name: String, nameRU: String)] = [
        ("🐶", "Dog", "Собака"), ("🐱", "Cat", "Кошка"), ("🦁", "Lion", "Лев"), ("🐎", "Horse", "Лошадь"),
        ("🦄", "Unicorn", "Единорог"), ("🐷", "Pig", "Свинья"), ("🐘", "Elephant", "Слон"), ("🐰", "Rabbit", "Кролик"),
        ("🐼", "Panda", "Панда"), ("🐓", "Rooster", "Петух"), ("🐧", "Penguin", "Пингвин"), ("🐢", "Turtle", "Черепаха"),
        ("🐟", "Fish", "Рыба"), ("🐙", "Octopus", "Осьминог"), ("🦋", "Butterfly", "Бабочка"), ("🌷", "Flower", "Цветок"),
        ("🌳", "Tree", "Дерево"), ("🌵", "Cactus", "Кактус"), ("🍄", "Mushroom", "Гриб"), ("🌏", "Globe", "Глобус"),
        ("🌙", "Moon", "Луна"), ("☁️", "Cloud", "Облако"), ("🔥", "Fire", "Огонь"), ("🍌", "Banana", "Банан"),
        ("🍎", "Apple", "Яблоко"), ("🍓", "Strawberry", "Клубника"), ("🌽", "Corn", "Кукуруза"), ("🍕", "Pizza", "Пицца"),
        ("🎂", "Cake", "Торт"), ("❤️", "Heart", "Сердце"), ("😀", "Smiley", "Улыбка"), ("🤖", "Robot", "Робот"),
        ("🎩", "Hat", "Шляпа"), ("👓", "Glasses", "Очки"), ("🔧", "Spanner", "Ключ"), ("🎅", "Santa", "Санта"),
        ("👍", "Thumbs Up", "Большой палец вверх"), ("☂️", "Umbrella", "Зонт"), ("⌛", "Hourglass", "Песочные часы"), ("⏰", "Clock", "Часы"),
        ("🎁", "Gift", "Подарок"), ("💡", "Light Bulb", "Лампочка"), ("📕", "Book", "Книга"), ("✏️", "Pencil", "Карандаш"),
        ("📎", "Paperclip", "Скрепка"), ("✂️", "Scissors", "Ножницы"), ("🔒", "Lock", "Замок"), ("🔑", "Key", "Ключ"),
        ("🔨", "Hammer", "Молоток"), ("☎️", "Telephone", "Телефон"), ("🏁", "Flag", "Флаг"), ("🚂", "Train", "Поезд"),
        ("🚲", "Bicycle", "Велосипед"), ("✈️", "Aeroplane", "Самолет"), ("🚀", "Rocket", "Ракета"), ("🏆", "Trophy", "Кубок"),
        ("⚽", "Ball", "Мяч"), ("🎸", "Guitar", "Гитара"), ("🎺", "Trumpet", "Труба"), ("🔔", "Bell", "Колокол"),
        ("⚓", "Anchor", "Якорь"), ("🎧", "Headphones", "Наушники"), ("📁", "Folder", "Папка"), ("📌", "Pin", "Булавка"),
    ]
}
