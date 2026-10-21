// Нютаг. «Поддержать Нютаг»: три разовые покупки из App Store (те же, что у прежнего клиента, приложение одно).
// Ничего не открывают в приложении: это просьба помочь оплатить серверы. StoreKit 2, без сторонних библиотек.

import StoreKit
import SwiftUI

struct DonateView: View {
    static let productIDs = ["chat.nyutag.messenger.donate.small",
                             "chat.nyutag.messenger.donate.medium",
                             "chat.nyutag.messenger.donate.large"]

    @Environment(Words.self) private var words
    @Environment(\.dismiss) private var dismiss
    @State private var products: [Product] = []
    @State private var loading = true
    @State private var buying: String?
    @State private var thanked = false
    @State private var unavailable = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Image(systemName: "heart.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(Theme.gold)
                        .accessibilityHidden(true)
                    Text(words(.donateBody))
                        .foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.center)
                    if thanked {
                        Text(words(.donateThanks))
                            .font(.headline)
                            .foregroundStyle(Theme.read)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("donate-thanks")
                    }
                    if loading {
                        ProgressView().padding()
                    } else if unavailable {
                        Text(words(.donateUnavailable))
                            .font(.footnote)
                            .foregroundStyle(Theme.quiet)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("donate-unavailable")
                    }
                    ForEach(products, id: \.id) { product in
                        Button { Task { await buy(product) } } label: {
                            HStack {
                                Text(product.displayName.isEmpty ? product.displayPrice : product.displayName)
                                Spacer()
                                if buying == product.id { ProgressView() } else { Text(product.displayPrice).bold() }
                            }
                            .padding(.horizontal, 18).padding(.vertical, 14)
                            .foregroundStyle(Theme.onGold)
                            .background(Theme.gold, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .disabled(buying != nil)
                    }
                }
                .padding(20)
            }
            .background(Theme.milk.ignoresSafeArea())
            .navigationTitle(words(.donate))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(words(.done)) { dismiss() } }
            }
            .task { await load() }
        }
    }

    private func load() async {
        loading = true
        products = ((try? await Product.products(for: Self.productIDs)) ?? []).sorted { $0.price < $1.price }
        unavailable = products.isEmpty
        loading = false
        #if DEBUG
        print("ui-check: донат, товаров \(products.count)")
        #endif
        // Оплата прошла, а приложение закрылось раньше, чем покупку закрыли: закрываем сейчас.
        for await result in Transaction.unfinished {
            if case .verified(let transaction) = result { await transaction.finish() }
        }
    }

    private func buy(_ product: Product) async {
        buying = product.id
        defer { buying = nil }
        do {
            if case .success(let result) = try await product.purchase() {
                if case .verified(let transaction) = result { await transaction.finish() }
                thanked = true
            }
        } catch {
            unavailable = true
        }
    }
}
