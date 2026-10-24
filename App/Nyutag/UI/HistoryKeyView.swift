// Нютаг. Карточка над списком чатов для установок, где старая версия заперла историю отдельным ключом.
// Ключ больше не спрашиваем: новый вход паролем заводит хранилище под паролем, и дальше история сохраняется.

import SwiftUI

/// Карточка над списком: золотая полоска слева, замок, по нажатию предлагает выйти и войти снова.
struct LockedHistoryCard: View {
    @Environment(Words.self) private var words
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: "key.horizontal.fill")
                    .font(.title3).foregroundStyle(Theme.onGold)
                    .frame(width: 40, height: 40)
                    .background(Theme.gold, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(words(.historyLockedTitle)).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                    Text(words(.historyLockedLead)).font(.footnote).foregroundStyle(Theme.quiet)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.quiet)
            }
            .padding(12)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(alignment: .leading) { Theme.gold.frame(width: 5) }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("history-locked")
    }
}
