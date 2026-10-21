// Исчезающее фото вживую: учётка Мака (третья) шлёт фото с меткой `chat.nyutag.view_once` в группу «Проверка
// групповых звонков» и ждёт, пока получатель (симулятор с NYUTAG_UI_OPEN) откроет его и удалит реплику.
// Фото уходит открытым содержимым: проверяется путь получателя, шифрованные вложения проверены отдельно.
//   NYUTAG_VIEW_ONCE=1, NYUTAG_TEST_THIRD_USER/_PASSWORD; NYUTAG_VIEW_ONCE_WAIT — сколько ждать (по умолчанию 180 с).

import CoreGraphics
import Foundation
import ImageIO
@testable import NyutagCore
import Testing
import UniformTypeIdentifiers

@Suite(.enabled(if: ProcessInfo.processInfo.environment["NYUTAG_VIEW_ONCE"] != nil && LiveEnv.homeserver != nil
                    && ProcessInfo.processInfo.environment["NYUTAG_TEST_THIRD_USER"] != nil, "нет NYUTAG_VIEW_ONCE"))
struct LiveViewOnceTests {
    static let env = ProcessInfo.processInfo.environment

    @Test func receiverOpensOnceAndDeletes() async throws {
        let client = MatrixClient(homeserver: LiveEnv.homeserver!)
        let session = try await client.login(user: Self.env["NYUTAG_TEST_THIRD_USER"]!, password: Self.env["NYUTAG_TEST_THIRD_PASSWORD"]!,
                                   deviceDisplayName: "Нютаг тест исчезающего фото (Мак)")
        do {
            try await run(client, session)
        } catch {
            try? await client.logout()
            throw error
        }
        try await client.logout()
    }

    private func run(_ client: MatrixClient, _ session: Session) async throws {
        let store = try Store.inMemory()
        let engine = SyncEngine(client: client, store: store, session: session)
        _ = try await engine.syncOnce()
        let room = try #require(try await store.rooms(membership: .join).first { $0.name == "Проверка групповых звонков" }?.id,
                                "учётка не в группе")
        let jpeg = try Self.jpeg()
        let mxc = try await client.uploadMedia(jpeg, contentType: "image/jpeg", filename: "once.jpg")
        let content = Attachment.content(.plain(mxc), name: "once.jpg", mimetype: "image/jpeg", size: jpeg.count,
                                         width: 320, height: 240, viewOnce: true)
        let eventID = try await client.send(roomID: room, type: EventType.message, content: content)
        print("view once: фото ушло, \(eventID.prefix(8))…, жду просмотра")

        let wait = Self.env["NYUTAG_VIEW_ONCE_WAIT"].flatMap(Double.init) ?? 180
        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline {
            let event = try await client.event(roomID: room, eventID: eventID)
            if event.isRedacted {
                print("view once: получатель открыл и удалил, удалил \(event.unsigned?["redacted_because"]?["sender"]?.string ?? "?")")
                return
            }
            try await Task.sleep(for: .seconds(3))
        }
        let last = try? await client.event(roomID: room, eventID: eventID)
        print("view once: в конце content \(last?.content.object?.keys.sorted() ?? []), unsigned \(last?.unsigned?.object?.keys.sorted() ?? [])")
        Issue.record("фото не удалено за \(Int(wait)) с")
        _ = try? await client.redact(roomID: room, eventID: eventID)
    }

    /// Полосатая картинка 320×240.
    static func jpeg() throws -> Data {
        let context = try #require(CGContext(data: nil, width: 320, height: 240, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        for i in 0..<8 {
            context.setFillColor(CGColor(red: CGFloat(i) / 8, green: 0.5, blue: 1 - CGFloat(i) / 8, alpha: 1))
            context.fill(CGRect(x: i * 40, y: 0, width: 40, height: 240))
        }
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
