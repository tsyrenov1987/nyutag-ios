// Нютаг. Свой облик: синий неба и золото соёмбо со значка, молочный фон, карточки вместо линеек-разделителей,
// аватары-«подушки» (скруглённый квадрат), счётчики золотые. Красного в интерфейсе нет вовсе: красная точка
// у прежнего клиента читалась как ошибка.

import SwiftUI

enum Theme {
    static let sky = Color(light: 0x2347A6, dark: 0x6F95F2)
    static let gold = Color(light: 0xC9971C, dark: 0xE2B84A)
    static let onGold = Color(light: 0x2A1F05, dark: 0x1C1404)
    static let milk = Color(light: 0xF4F0E6, dark: 0x0D121C)
    static let card = Color(light: 0xFFFFFF, dark: 0x172031)
    static let ink = Color(light: 0x18202E, dark: 0xECEFF5)
    static let quiet = Color(light: 0x6B7280, dark: 0x9AA3B5)
    static let read = Color(light: 0x1F8A5B, dark: 0x4FD39A)
    static let readOnBlue = Color(light: 0x8FF0C0, dark: 0x8FF0C0)
    /// Подложка служебных плашек и разделителей дней: темнее фона, чтобы не сливаться с ним.
    static let plate = Color(light: 0xE4DDCB, dark: 0x222C40)
    /// Свои пузыри: синий неба с белым текстом; чужие — белая карточка.
    static let mine = Color(light: 0x2347A6, dark: 0x2F55B8)

    /// Пять цветов для аватаров без картинки; цвет выбирается по идентификатору и не меняется.
    static let avatarTints: [Color] = [
        Color(light: 0x2347A6, dark: 0x3F66CC), Color(light: 0x1F7A57, dark: 0x2E9B70),
        Color(light: 0xB5761A, dark: 0xC98C2E), Color(light: 0x7A3E9D, dark: 0x9459B8),
        Color(light: 0x2E7D8C, dark: 0x3C9AAB),
    ]
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

/// Знак Нютага, как на иконке: юрта-реплика с соёмбо на синем значка.
struct NyutagLogo: View {
    var size: CGFloat = 96

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(Color("LogoBlue").gradient)
            .overlay { Image("LogoMark").resizable().scaledToFit().padding(size * 0.2) }
            .frame(width: size, height: size)
            .accessibilityLabel("Нютаг")
    }
}

/// Аватар: картинка из медиа (`avatar` — адрес mxc://) поверх первой буквы на цвете из пятёрки.
/// Пока картинка грузится или если её нет, видна буква.
struct Pillow: View {
    let seed: String
    let title: String
    var size: CGFloat = 52
    var avatar: String? = nil

    var body: some View {
        let tint = Theme.avatarTints[Int(Self.stableHash(seed) % UInt32(Theme.avatarTints.count))]
        let shape = RoundedRectangle(cornerRadius: size * 0.34, style: .continuous)
        shape
            .fill(tint.gradient)
            .overlay {
                Text(Self.initial(title))
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .overlay {
                if let avatar { AvatarPicture(url: avatar, size: size) }
            }
            .clipShape(shape)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    static func initial(_ title: String) -> String {
        let letter = title.trimmingCharacters(in: .whitespaces).drop { !$0.isLetter && !$0.isNumber }.first
        return letter.map { String($0).uppercased() } ?? "·"
    }

    /// FNV-1a: `hashValue` у строк меняется между запусками, а цвет должен быть постоянным.
    static func stableHash(_ text: String) -> UInt32 {
        text.utf8.reduce(2_166_136_261) { ($0 ^ UInt32($1)) &* 16_777_619 }
    }
}

/// Квадратная миниатюра аватара из кэша медиа; не загрузилась — пусто, снизу остаётся буква.
struct AvatarPicture: View {
    @Environment(AppSession.self) private var session
    let url: String
    let size: CGFloat
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .task(id: url) { image = await session.avatar(url, pixels: Int(size * 3)) }
    }
}
