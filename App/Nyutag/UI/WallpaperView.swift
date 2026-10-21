// Нютаг. Обои чатов: общие для всех чатов и свои для отдельного чата, как в Telegram. Выбор живёт только на
// этом телефоне (на сервер не уходит). Узоры рисуются кодом, без картинок: волны Байкала, холмы степи, звёзды.
// Своё фото из галереи хранится файлом рядом с данными приложения и приглушается, чтобы пузыри читались.

import PhotosUI
import SwiftUI

enum Wallpaper: String, CaseIterable, Identifiable {
    case milk, baikal, steppe, dawn, night, photo

    var id: Self { self }
    /// Варианты-узоры; фото выбирают отдельной кнопкой.
    static let drawn: [Wallpaper] = [.milk, .baikal, .steppe, .dawn, .night]

    var phrase: Phrase {
        switch self {
        case .milk: .wallpaperMilk
        case .baikal: .wallpaperBaikal
        case .steppe: .wallpaperSteppe
        case .dawn: .wallpaperDawn
        case .night: .wallpaperNight
        case .photo: .wallpaperPhoto
        }
    }
}

/// Где что выбрано. Ключ «all» — для всех чатов, иначе номер комнаты.
@Observable
final class Wallpapers {
    private let defaults: UserDefaults
    /// Меняется при каждой замене фото: картинку надо перечитать с диска.
    private(set) var photoVersion = 0
    private var choices: [String: String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        choices = defaults.dictionary(forKey: "wallpapers") as? [String: String] ?? [:]
    }

    static let all = "all"

    /// Своё для чата или nil — как во всех.
    func own(_ roomID: String) -> Wallpaper? { choices[roomID].flatMap(Wallpaper.init(rawValue:)) }

    func general() -> Wallpaper { choices[Self.all].flatMap(Wallpaper.init(rawValue:)) ?? .milk }

    func resolved(_ roomID: String) -> (wallpaper: Wallpaper, key: String) {
        if let own = own(roomID) { return (own, roomID) }
        return (general(), Self.all)
    }

    func set(_ wallpaper: Wallpaper?, for key: String) {
        choices[key] = wallpaper?.rawValue
        if wallpaper != .photo { try? FileManager.default.removeItem(at: Self.photoURL(key)) }
        defaults.set(choices, forKey: "wallpapers")
    }

    func setPhoto(_ data: Data, for key: String) -> Bool {
        guard let image = UIImage(data: data), let jpeg = Self.shrunk(image).jpegData(compressionQuality: 0.85) else { return false }
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try jpeg.write(to: Self.photoURL(key), options: .atomic)
        } catch {
            return false
        }
        set(.photo, for: key)
        photoVersion += 1
        return true
    }

    func photo(_ key: String) -> UIImage? {
        _ = photoVersion
        return UIImage(contentsOfFile: Self.photoURL(key).path)
    }

    private static var folder: URL {
        URL.applicationSupportDirectory.appending(path: "wallpapers", directoryHint: .isDirectory)
    }

    /// Имя файла без «!» и «:» из номера комнаты.
    private static func photoURL(_ key: String) -> URL {
        folder.appending(path: key == all ? "all.jpg" : "\(Pillow.stableHash(key)).jpg")
    }

    /// Хватает экрана телефона: большие фото из камеры зря занимали бы место и память.
    private static func shrunk(_ image: UIImage) -> UIImage {
        let longest: CGFloat = 2000
        let side = max(image.size.width, image.size.height)
        guard side > longest else { return image }
        let scale = longest / side
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }
}

/// Фон под лентой чата.
struct WallpaperBackground: View {
    @Environment(Wallpapers.self) private var wallpapers
    let roomID: String

    var body: some View {
        let (wallpaper, key) = wallpapers.resolved(roomID)
        WallpaperFill(wallpaper: wallpaper, photo: wallpaper == .photo ? wallpapers.photo(key) : nil)
    }
}

struct WallpaperFill: View {
    let wallpaper: Wallpaper
    var photo: UIImage?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        switch wallpaper {
        case .milk: Theme.milk
        case .baikal: drawn(top: Color(light: 0xDCEAF5, dark: 0x0A1A2B), bottom: Color(light: 0xB9D3EA, dark: 0x0E2742)) { waves($0, $1) }
        case .steppe: drawn(top: Color(light: 0xF1EDD6, dark: 0x12160E), bottom: Color(light: 0xD6E3BC, dark: 0x1B2614)) { hills($0, $1) }
        case .dawn: drawn(top: Color(light: 0xF8E3D6, dark: 0x1E1420), bottom: Color(light: 0xF3D7A6, dark: 0x2B1F14)) { stars($0, $1, count: 26) }
        case .night: drawn(top: Color(light: 0x2A3358, dark: 0x070B18), bottom: Color(light: 0x18203F, dark: 0x111A33)) { stars($0, $1, count: 70) }
        case .photo:
            if let photo {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
                    .overlay(Theme.milk.opacity(scheme == .dark ? 0.45 : 0.25))
                    .clipped()
            } else {
                Theme.milk
            }
        }
    }

    private func drawn(top: Color, bottom: Color,
                       _ pattern: @escaping (GraphicsContext, CGSize) -> Void) -> some View {
        LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
            .overlay {
                Canvas { context, size in pattern(context, size) }
            }
            .accessibilityHidden(true)
    }

    private var line: Color { wallpaper == .night ? .white.opacity(0.10) : Theme.ink.opacity(0.07) }

    /// Байкал: ряды мелких волн, каждый ряд сдвинут на полволны.
    private func waves(_ context: GraphicsContext, _ size: CGSize) {
        let step: CGFloat = 34, length: CGFloat = 46, height: CGFloat = 5
        var row = 0
        var y: CGFloat = 12
        while y < size.height + step {
            var path = Path()
            var x = -length + (row.isMultiple(of: 2) ? 0 : length / 2)
            path.move(to: CGPoint(x: x, y: y))
            while x < size.width + length {
                path.addQuadCurve(to: CGPoint(x: x + length / 2, y: y), control: CGPoint(x: x + length / 4, y: y - height))
                path.addQuadCurve(to: CGPoint(x: x + length, y: y), control: CGPoint(x: x + length * 3 / 4, y: y + height))
                x += length
            }
            context.stroke(path, with: .color(line), lineWidth: 1.4)
            y += step
            row += 1
        }
    }

    /// Степь: пологие холмы внизу, чем ниже, тем плотнее.
    private func hills(_ context: GraphicsContext, _ size: CGSize) {
        for index in 0..<7 {
            let base = size.height * (0.38 + CGFloat(index) * 0.09)
            let amplitude = 18 + CGFloat(index % 3) * 8
            let period = size.width * (0.9 + CGFloat(index % 2) * 0.5)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: base))
            for x in stride(from: CGFloat(0), through: size.width, by: 6) {
                let phase = CGFloat(index) * 1.7
                path.addLine(to: CGPoint(x: x, y: base - amplitude * sin(x / period * 2 * .pi + phase)))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.addLine(to: CGPoint(x: 0, y: size.height))
            path.closeSubpath()
            context.fill(path, with: .color(Color(light: 0x6E8F3A, dark: 0x9BC05A).opacity(0.045)))
        }
    }

    /// Звёзды: места выводятся из номера, поэтому одинаковы при каждой перерисовке.
    private func stars(_ context: GraphicsContext, _ size: CGSize, count: Int) {
        let ink = wallpaper == .night ? Color.white.opacity(0.55) : Theme.gold.opacity(0.35)
        var seed: UInt32 = 2_166_136_261
        func next() -> CGFloat {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return CGFloat(seed >> 8) / CGFloat(1 << 24)
        }
        let tile: CGFloat = 400
        var spots: [(CGPoint, CGFloat)] = []
        for _ in 0..<count { spots.append((CGPoint(x: next() * tile, y: next() * tile), 0.8 + next() * 1.8)) }
        for row in 0...Int(size.height / tile) {
            for column in 0...Int(size.width / tile) {
                for (point, radius) in spots {
                    let center = CGPoint(x: point.x + CGFloat(column) * tile, y: point.y + CGFloat(row) * tile)
                    context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                        width: radius * 2, height: radius * 2)), with: .color(ink))
                }
            }
        }
    }
}

/// Выбор обоев: для всех чатов (`roomID == nil`) или для одного.
struct WallpaperPicker: View {
    @Environment(Words.self) private var words
    @Environment(Wallpapers.self) private var wallpapers
    @Environment(\.dismiss) private var dismiss
    var roomID: String?
    @State private var photoItem: PhotosPickerItem?
    @State private var photoFailed = false

    private var key: String { roomID ?? Wallpapers.all }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    preview
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12)], spacing: 12) {
                        if roomID != nil {
                            tile(nil)
                        }
                        ForEach(Wallpaper.drawn) { tile($0) }
                    }
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label(words(.wallpaperPickPhoto), systemImage: "photo")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("wallpaper-photo")
                    if photoFailed {
                        Text(words(.wallpaperPhotoFailed)).font(.footnote).foregroundStyle(.red)
                    }
                }
                .padding(16)
            }
            .background(Theme.milk.ignoresSafeArea())
            .navigationTitle(words(roomID == nil ? .wallpaper : .wallpaperForChat))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(words(.done)) { dismiss() } }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    let data = try? await item.loadTransferable(type: Data.self)
                    photoFailed = !(data.map { wallpapers.setPhoto($0, for: key) } ?? false)
                    photoItem = nil
                }
            }
            #if DEBUG
            .task { pickForScreenshots() }
            #endif
        }
    }

    /// Как будет выглядеть чат: два пузыря на выбранном фоне.
    private var preview: some View {
        let (wallpaper, shownKey) = roomID.map(wallpapers.resolved) ?? (wallpapers.general(), Wallpapers.all)
        return VStack(spacing: 8) {
            bubble(words(.wallpaperSampleTheirs), mine: false)
            bubble(words(.wallpaperSampleMine), mine: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 170)
        .background {
            WallpaperFill(wallpaper: wallpaper, photo: wallpaper == .photo ? wallpapers.photo(shownKey) : nil)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func bubble(_ text: String, mine: Bool) -> some View {
        Text(text)
            .foregroundStyle(mine ? .white : Theme.ink)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(mine ? Theme.mine : Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }

    /// nil — «как во всех чатах».
    private func tile(_ wallpaper: Wallpaper?) -> some View {
        let chosen = roomID.map { wallpapers.own($0) == wallpaper } ?? (wallpapers.general() == wallpaper)
        return Button {
            wallpapers.set(wallpaper, for: key)
        } label: {
            VStack(spacing: 6) {
                Group {
                    if let wallpaper {
                        WallpaperFill(wallpaper: wallpaper)
                    } else {
                        WallpaperFill(wallpaper: wallpapers.general(),
                                      photo: wallpapers.general() == .photo ? wallpapers.photo(Wallpapers.all) : nil)
                            .overlay(Image(systemName: "arrow.uturn.backward").foregroundStyle(Theme.quiet))
                    }
                }
                .frame(height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(chosen ? Theme.sky : Theme.plate, lineWidth: chosen ? 3 : 1)
                }
                Text(words(wallpaper?.phrase ?? .wallpaperAsEverywhere))
                    .font(.footnote)
                    .foregroundStyle(chosen ? Theme.sky : Theme.ink)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityIdentifier("wallpaper-\(wallpaper?.rawValue ?? "general")")
    }

    #if DEBUG
    /// SIMCTL_CHILD_NYUTAG_UI_WALLPAPER=baikal — выбрать вариант при открытии окна.
    private func pickForScreenshots() {
        guard let name = ProcessInfo.processInfo.environment["NYUTAG_UI_WALLPAPER"] else { return }
        wallpapers.set(Wallpaper(rawValue: name), for: key)
        print("ui-check: обои \(key == Wallpapers.all ? "всех чатов" : "чата") = \(name)")
    }
    #endif
}
