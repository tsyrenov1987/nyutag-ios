// Нютаг. Встроенный набор стикеров с соёмбо: знак рисуется кодом (огонь, солнце, луна, наконечники, плашки,
// две рыбы и столбы по бокам), подписи — короткие бурятские приветствия. Картинка загружается на сервер
// при первой отправке, адрес запоминается, дальше отправляется без загрузки. Получатель видит обычный `m.sticker`.

import UIKit

nonisolated enum Soyombo {
    /// Высота знака в своих единицах при ширине 100.
    static let height: CGFloat = 208

    /// Знак в прямоугольнике `rect` (пропорции сохраняются, по центру).
    static func draw(in rect: CGRect, color: UIColor, context: CGContext) {
        let scale = min(rect.width / 100, rect.height / height)
        context.saveGState()
        context.translateBy(x: rect.midX - 50 * scale, y: rect.midY - height / 2 * scale)
        context.scaleBy(x: scale, y: scale)
        color.setFill()
        color.setStroke()

        // Огонь: три языка, средний выше.
        let fire = UIBezierPath()
        fire.move(to: CGPoint(x: 20, y: 40))
        fire.addQuadCurve(to: CGPoint(x: 29, y: 13), controlPoint: CGPoint(x: 17, y: 24))
        fire.addQuadCurve(to: CGPoint(x: 39, y: 30), controlPoint: CGPoint(x: 34, y: 22))
        fire.addQuadCurve(to: CGPoint(x: 50, y: 0), controlPoint: CGPoint(x: 38, y: 12))
        fire.addQuadCurve(to: CGPoint(x: 61, y: 30), controlPoint: CGPoint(x: 62, y: 12))
        fire.addQuadCurve(to: CGPoint(x: 71, y: 13), controlPoint: CGPoint(x: 66, y: 22))
        fire.addQuadCurve(to: CGPoint(x: 80, y: 40), controlPoint: CGPoint(x: 83, y: 24))
        fire.close()
        fire.fill()

        // Солнце.
        UIBezierPath(ovalIn: CGRect(x: 39, y: 43, width: 22, height: 22)).fill()

        // Луна: нижний серп.
        context.saveGState()
        let outer = UIBezierPath(ovalIn: CGRect(x: 32, y: 52, width: 36, height: 36))
        outer.addClip()
        let moon = UIBezierPath(ovalIn: CGRect(x: 32, y: 52, width: 36, height: 36))
        moon.append(UIBezierPath(ovalIn: CGRect(x: 32, y: 46, width: 36, height: 36)))
        moon.usesEvenOddFillRule = true
        moon.fill()
        context.restoreGState()

        // Наконечник, плашка, две рыбы, плашка, наконечник.
        triangle(top: 92)
        UIBezierPath(rect: CGRect(x: 18, y: 113, width: 64, height: 8)).fill()
        fishes(center: CGPoint(x: 50, y: 150), radius: 24, context: context)
        UIBezierPath(rect: CGRect(x: 18, y: 179, width: 64, height: 8)).fill()
        triangle(top: 190)

        // Столбы по бокам.
        UIBezierPath(rect: CGRect(x: 0, y: 92, width: 11, height: 116)).fill()
        UIBezierPath(rect: CGRect(x: 89, y: 92, width: 11, height: 116)).fill()
        context.restoreGState()
    }

    private static func triangle(top: CGFloat) {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 18, y: top))
        path.addLine(to: CGPoint(x: 82, y: top))
        path.addLine(to: CGPoint(x: 50, y: top + 18))
        path.close()
        path.fill()
    }

    /// Две рыбы в круге: залитая половина с изгибом, обводка и «глаза».
    private static func fishes(center c: CGPoint, radius r: CGFloat, context: CGContext) {
        let half = r / 2
        let fish = UIBezierPath()
        fish.move(to: CGPoint(x: c.x, y: c.y - r))
        fish.addArc(withCenter: c, radius: r, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: true)
        fish.addArc(withCenter: CGPoint(x: c.x, y: c.y + half), radius: half, startAngle: .pi / 2, endAngle: -.pi / 2, clockwise: true)
        fish.addArc(withCenter: CGPoint(x: c.x, y: c.y - half), radius: half, startAngle: .pi / 2, endAngle: -.pi / 2, clockwise: false)
        fish.close()
        fish.fill()
        let ring = UIBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        ring.lineWidth = 3
        ring.stroke()
        let eye = r / 6
        UIBezierPath(ovalIn: CGRect(x: c.x - eye, y: c.y - half - eye, width: 2 * eye, height: 2 * eye)).fill()
        context.setBlendMode(.clear)
        UIBezierPath(ovalIn: CGRect(x: c.x - eye, y: c.y + half - eye, width: 2 * eye, height: 2 * eye)).fill()
        context.setBlendMode(.normal)
    }
}

/// Стикер встроенного набора: короткое имя и подпись (без подписи — один знак).
nonisolated struct SoyomboSticker: Identifiable, Hashable {
    let shortcode: String
    let caption: String?

    var id: String { shortcode }
    /// Подпись события: её видят в уведомлениях и в клиентах без картинок.
    var body: String { caption ?? "Соёмбо" }

    /// Версия рисунка: поменялся рисунок — меняем, и картинка загрузится заново.
    static let version = 1

    static let all: [SoyomboSticker] = [
        SoyomboSticker(shortcode: "soyombo", caption: nil),
        SoyomboSticker(shortcode: "sain-baina", caption: "Сайн байна!"),
        SoyomboSticker(shortcode: "bayarlaa", caption: "Баярлаа!"),
        SoyomboSticker(shortcode: "bayartai", caption: "Баяртай!"),
        SoyomboSticker(shortcode: "sagaan-haraar", caption: "Сагаан һараар!"),
    ]

    private static let gold = UIColor(red: 0xC9 / 255, green: 0x97 / 255, blue: 0x1C / 255, alpha: 1)
    private static let blue = UIColor(red: 0x23 / 255, green: 0x47 / 255, blue: 0xA6 / 255, alpha: 1)

    /// Картинка 512×512 на прозрачном фоне.
    func image(side: CGFloat = 512) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { renderer in
            let context = renderer.cgContext
            guard let caption else {
                Soyombo.draw(in: CGRect(x: 0, y: 0, width: side, height: side).insetBy(dx: side * 0.06, dy: side * 0.04),
                             color: Self.gold, context: context)
                return
            }
            Soyombo.draw(in: CGRect(x: 0, y: side * 0.03, width: side, height: side * 0.56), color: Self.gold, context: context)
            // Подпись на синей плашке: белые буквы, ширина под текст.
            let plate = CGRect(x: side * 0.04, y: side * 0.64, width: side * 0.92, height: side * 0.32)
            Self.blue.setFill()
            UIBezierPath(roundedRect: plate, cornerRadius: plate.height / 2.4).fill()
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            var size = side * 0.13
            var text: NSAttributedString
            repeat {
                let base = UIFont.systemFont(ofSize: size, weight: .heavy)
                let font = base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: size) } ?? base
                text = NSAttributedString(string: caption, attributes: [.font: font, .foregroundColor: UIColor.white, .paragraphStyle: paragraph])
                size -= 2
            } while text.size().width > plate.width * 0.9 && size > 20
            let height = text.size().height
            text.draw(in: CGRect(x: plate.minX, y: plate.midY - height / 2, width: plate.width, height: height))
        }
    }

    var png: Data? { image().pngData() }
}
