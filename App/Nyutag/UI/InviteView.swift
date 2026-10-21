// Нютаг. «Пригласить друга»: в Нютаг попадают по одноразовому коду. Экран показывает свежий код крупно и QR
// ссылки на страницу приглашения, отдаёт готовый текст в «Поделиться» и держит список своих кодов с отзывом.
// Неиспользованный живой код показываем повторно, а не выпускаем новый на каждое открытие: у сервера лимит.

import CoreImage.CIFilterBuiltins
import NyutagCore
import SwiftUI

struct InviteView: View {
    @Environment(Words.self) private var words
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var current: InviteCode?
    @State private var mine: [(invite: InviteCode, usedBy: String?)] = []
    @State private var busy = false
    @State private var failure: AppSession.InviteFailure?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    card
                } footer: {
                    Text(words(.inviteHint))
                }
                if !mine.isEmpty {
                    Section(words(.inviteMine)) {
                        ForEach(mine, id: \.invite.code) { item in
                            row(item.invite, usedBy: item.usedBy)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.milk.ignoresSafeArea())
            .navigationTitle(words(.inviteFriend))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(words(.done)) { dismiss() } }
            }
            .task { await load() }
        }
    }

    @ViewBuilder private var card: some View {
        VStack(spacing: 14) {
            if let current {
                if let qr = Self.qr(current.link) {
                    Image(uiImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 200, height: 200)
                        .padding(10)
                        .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .accessibilityHidden(true)
                }
                Text(current.code)
                    .font(.system(.title, design: .monospaced).bold())
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("invite-code")
                HStack(spacing: 12) {
                    ShareLink(item: words(.inviteShareText, current.code, current.link)) {
                        Label(words(.inviteShare), systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    Button(words(.copy), systemImage: "doc.on.doc") { UIPasteboard.general.string = current.code }
                        .buttonStyle(.bordered)
                }
            } else if busy {
                ProgressView(words(.inviteCreating)).padding(.vertical, 40)
            }
            if let failure {
                Text(words(Self.phrase(failure)))
                    .font(.footnote).multilineTextAlignment(.center)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("invite-failure")
            }
            if current != nil || failure != nil {
                Button(words(.inviteNew)) { Task { await make() } }
                    .font(.footnote)
                    .disabled(busy)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    @ViewBuilder private func row(_ invite: InviteCode, usedBy: String?) -> some View {
        let alive = usedBy == nil && (invite.expiresAt ?? .distantFuture) > Date()
        VStack(alignment: .leading, spacing: 2) {
            Text(invite.code).font(.body.monospaced()).foregroundStyle(alive ? Theme.ink : Theme.quiet)
            Text(status(invite, usedBy: usedBy)).font(.caption).foregroundStyle(Theme.quiet)
        }
        .swipeActions {
            if alive {
                Button(words(.inviteRevoke), role: .destructive) { Task { await revoke(invite.code) } }
            }
        }
        .contextMenu {
            if alive {
                Button(words(.inviteRevoke), systemImage: "xmark.circle", role: .destructive) { Task { await revoke(invite.code) } }
            }
        }
    }

    private func status(_ invite: InviteCode, usedBy: String?) -> String {
        if let usedBy { return words(.inviteUsedBy, ChatDigest.localpart(usedBy)) }
        guard let expires = invite.expiresAt else { return "" }
        if expires <= Date() { return words(.inviteExpired) }
        let locale = (words.lang ?? .ru).locale
        return words(.inviteValidTill, expires.formatted(.dateTime.day().month(.wide).hour().minute().locale(locale)))
    }

    private func load() async {
        busy = true
        let list = await session.myInvites() ?? []
        mine = list
        busy = false
        let fresh = list.first { $0.usedBy == nil && ($0.invite.expiresAt ?? .distantFuture) > Date() }?.invite
        if let fresh { current = fresh } else { await make() }
        #if DEBUG
        print("ui-check: приглашение \(current == nil ? "нет: \(String(describing: failure))" : "показано"), кодов \(mine.count)")
        #endif
    }

    private func make() async {
        busy = true
        defer { busy = false }
        do throws(AppSession.InviteFailure) {
            let invite = try await session.createInvite()
            current = invite
            failure = nil
            mine = await session.myInvites() ?? mine
        } catch {
            failure = error
        }
    }

    private func revoke(_ code: String) async {
        guard await session.revokeInvite(code) else { return }
        mine.removeAll { $0.invite.code == code }
        if current?.code == code { current = nil }
    }

    private static func phrase(_ failure: AppSession.InviteFailure) -> Phrase {
        switch failure {
        case .limit: .inviteLimit
        case .noNetwork: .noNetwork
        case .broken: .inviteFailed
        }
    }

    /// QR рисует система (Core Image), без сторонних библиотек.
    static func qr(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
