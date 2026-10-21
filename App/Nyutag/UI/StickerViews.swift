// Нютаг. Стикеры: картинка стикера в ленте и в наборе, окно выбора (свой набор + наборы комнаты),
// добавление из галереи (PNG до 512 точек, прозрачность сохраняется).

import NyutagCore
import PhotosUI
import SwiftUI

/// Картинка стикера по адресу: качается целиком, кэш общий с лентой.
struct StickerImage: View {
    @Environment(AppSession.self) private var session
    let mxc: MXC
    var size: CGFloat = 160
    var local: UIImage?
    @State private var image: UIImage?
    @State private var broken = false

    var body: some View {
        ZStack {
            if let shown = local ?? image {
                Image(uiImage: shown).resizable().scaledToFit()
            } else if broken {
                Image(systemName: "face.dashed").font(.title2).foregroundStyle(Theme.quiet)
            } else {
                ProgressView()
            }
        }
        .frame(width: size, height: size)
        .task(id: mxc.description) { await load() }
    }

    private func load() async {
        guard local == nil, image == nil else { return }
        let key = "sticker:" + mxc.description
        if let known = ImageMemory.get(key) { image = known; return }
        guard let data = await session.stickerData(mxc) else { broken = true; return }
        let decoded = await Task.detached(priority: .userInitiated) { ImageMemory.downsample(data, maxPixels: 512) }.value
        guard let decoded else { broken = true; return }
        ImageMemory.put(decoded, key)
        image = decoded
    }
}

/// Окно выбора стикера: свой набор (с добавлением и удалением) и наборы комнаты.
struct StickerPicker: View {
    @Environment(Words.self) private var words
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let roomID: String
    let onPick: (Sticker) -> Void
    @State private var mine: StickerPack?
    @State private var packs: [StickerPack] = []
    @State private var pickingPhoto = false
    @State private var photoItem: PhotosPickerItem?
    @State private var adding = false
    @State private var failed = false
    @State private var sendingSoyombo: String?

    private let columns = [GridItem(.adaptive(minimum: 76), spacing: 10)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    soyombo
                    section(title: mine?.name ?? words(.stickerMine), stickers: mine?.stickers ?? [], own: true)
                    ForEach(packs, id: \.name) { pack in
                        section(title: pack.name, stickers: pack.stickers, own: false)
                    }
                }
                .padding(16)
            }
            .background(Theme.milk.ignoresSafeArea())
            .navigationTitle(words(.stickers))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(words(.done)) { dismiss() } }
            }
            .photosPicker(isPresented: $pickingPhoto, selection: $photoItem, matching: .images)
            .onChange(of: photoItem) { _, picked in
                guard let picked else { return }
                photoItem = nil
                Task { await add(picked) }
            }
            .alert(words(.stickerFailed), isPresented: $failed) { Button(words(.done)) {} }
            .task(id: session.revision) {
                mine = await session.myStickers()
                packs = await session.roomStickers(roomID)
                #if DEBUG
                print("ui-check: стикеры: своих \(mine?.stickers.count ?? 0), наборов комнаты \(packs.count)")
                #endif
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder private func section(title: String, stickers: [Sticker], own: Bool) -> some View {
        Text(title).font(.headline).foregroundStyle(Theme.ink)
        if own, stickers.isEmpty, mine != nil {
            Text(words(.stickerNone)).font(.footnote).foregroundStyle(Theme.quiet)
        }
        LazyVGrid(columns: columns, spacing: 10) {
            if own {
                Button { pickingPhoto = true } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card)
                        if adding { ProgressView() } else { Image(systemName: "plus").font(.title2).foregroundStyle(Theme.sky) }
                    }
                    .frame(height: 76)
                }
                .disabled(adding)
                .accessibilityLabel(words(.stickerAdd))
                .accessibilityIdentifier("sticker-add")
            }
            ForEach(stickers) { sticker in
                Button {
                    onPick(sticker)
                    dismiss()
                } label: {
                    StickerImage(mxc: sticker.mxc, size: 76)
                        .padding(4)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(sticker.body)
                .accessibilityIdentifier("sticker-\(sticker.shortcode)")
                .contextMenu {
                    if own {
                        Button(words(.stickerRemove), systemImage: "trash", role: .destructive) {
                            Task { _ = await session.removeSticker(sticker.shortcode) }
                        }
                    } else {
                        Button(words(.stickerSave), systemImage: "plus.square.on.square") {
                            Task { if await session.addSticker(sticker) == nil { failed = true } }
                        }
                    }
                }
            }
        }
    }

    /// Встроенный набор: картинки рисуются на месте, на сервер уходят при первой отправке.
    @ViewBuilder private var soyombo: some View {
        Text(words(.stickerSoyombo)).font(.headline).foregroundStyle(Theme.ink)
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(SoyomboSticker.all) { item in
                Button { pick(item) } label: {
                    ZStack {
                        Image(uiImage: Self.soyomboImages[item.shortcode] ?? UIImage()).resizable().scaledToFit().frame(width: 76, height: 76)
                        if sendingSoyombo == item.shortcode { ProgressView() }
                    }
                    .padding(4)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(sendingSoyombo != nil)
                .accessibilityLabel(item.body)
                .accessibilityIdentifier("sticker-soyombo-\(item.shortcode)")
            }
        }
    }

    private static let soyomboImages: [String: UIImage] = Dictionary(uniqueKeysWithValues: SoyomboSticker.all.map {
        ($0.shortcode, $0.image(side: 228))
    })

    private func pick(_ item: SoyomboSticker) {
        sendingSoyombo = item.shortcode
        Task {
            defer { sendingSoyombo = nil }
            guard let sticker = await session.soyomboSticker(item) else { failed = true; return }
            onPick(sticker)
            dismiss()
        }
    }

    private func add(_ picked: PhotosPickerItem) async {
        adding = true
        defer { adding = false }
        guard let data = try? await picked.loadTransferable(type: Data.self),
              let png = await Task.detached(priority: .userInitiated, operation: { StickerMaker.png(data) }).value else {
            failed = true
            return
        }
        if await session.addSticker(png: png, name: "sticker-" + StickerMaker.stamp) == nil { failed = true }
    }
}

enum StickerMaker {
    /// Картинка из галереи в стикер: до 512 точек по длинной стороне, PNG с прозрачностью.
    nonisolated static func png(_ data: Data, side: CGFloat = 512) -> Data? {
        guard let image = ImageMemory.downsample(data, maxPixels: Int(side)) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let drawn = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        return drawn.pngData()
    }

    nonisolated static var stamp: String {
        Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).filter { $0.isNumber || $0 == "T" }
    }

    #if DEBUG
    /// Нарисованный стикер для проверки на телефоне: круг с буквой на прозрачном фоне.
    nonisolated static func drawn() -> Data? {
        let side: CGFloat = 512
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            UIColor(Theme.gold).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 16, y: 16, width: side - 32, height: side - 32))
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let text = NSAttributedString(string: "Ү", attributes: [
                .font: UIFont.systemFont(ofSize: 300, weight: .heavy), .foregroundColor: UIColor.white, .paragraphStyle: paragraph,
            ])
            text.draw(in: CGRect(x: 0, y: 80, width: side, height: 360))
        }
        return image.pngData()
    }
    #endif
}
