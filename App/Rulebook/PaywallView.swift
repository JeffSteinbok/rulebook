import SwiftUI
import StoreKit

/// Shown when a free user reaches a write action, naming the action they tried.
///
/// Deliberately not a launch-time wall: reading is the free tier, and the ask
/// lands at the moment someone has found a rule they want to fix.
struct PaywallView: View {
    let trigger: PaywallTrigger
    let pro: ProStore

    @Environment(\.dismiss) private var dismiss
    @State private var redeemingCode = false

    private let included = [
        "Edit, create, and delete rules",
        "Turn rules on and off",
        "Reorder them — order decides what runs",
        "Fix the rules that quietly stopped working",
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(trigger.headline)
                        .font(DS.Font.sectionTitle)
                        .foregroundStyle(DS.Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(pitch)
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Palette.ink60)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(included, id: \.self) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(DS.Palette.accent)
                                Text(line)
                                    .font(DS.Font.body)
                                    .foregroundStyle(DS.Palette.ink80)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.vertical, 4)

                    if let message = pro.errorMessage {
                        Text(message)
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Palette.destructive)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let notice = pro.notice {
                        Text(notice)
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Palette.ink80)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Metric.gutter)
            }
            .background(DS.Palette.ground)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    if pro.canStartTrial {
                        PrimaryButton(title: trialTitle, trailing: nil) {
                            Task {
                                await pro.startTrial()
                                if pro.isPro { dismiss() }
                            }
                        }
                        .disabled(pro.isWorking)

                        Button(buyTitle) {
                            Task {
                                await pro.purchase()
                                if pro.isPro { dismiss() }
                            }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(pro.product == nil || pro.isWorking)
                    } else {
                        PrimaryButton(title: buyTitle, trailing: nil) {
                            Task {
                                await pro.purchase()
                                if pro.isPro { dismiss() }
                            }
                        }
                        .disabled(pro.product == nil || pro.isWorking)
                    }

                    HStack(spacing: 24) {
                        Button("Restore purchase") {
                            Task {
                                await pro.restore()
                                if pro.isPro { dismiss() }
                            }
                        }
                        // Offer codes are how Pro is gifted: a redeemed code
                        // arrives as an ordinary Pro transaction.
                        Button("Redeem code") { redeemingCode = true }
                    }
                    .font(DS.Font.caption)
                    .disabled(pro.isWorking)
                }
                .padding(DS.Metric.gutter)
                .background(DS.Palette.ground)
            }
            .navigationTitle("Rulebook Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { dismiss() }
                }
            }
        }
        .task {
            // The product may not have loaded yet if the app opened offline.
            if pro.product == nil { await pro.loadProduct() }
        }
        .offerCodeRedemption(isPresented: $redeemingCode) { _ in
            Task {
                await pro.refresh()
                if pro.isPro { dismiss() }
            }
        }
        .onDisappear { pro.errorMessage = nil }
    }

    private var days: Int { Int(ProStore.trialLength / 86_400) }

    /// Guideline 3.1.1 asks a trial offer to say how long it lasts, what stops
    /// at the end, and what it costs after — all three are here.
    private var pitch: String {
        let price = pro.product.map { " of \($0.displayPrice)" } ?? ""
        if pro.canStartTrial {
            return "Reading your rules is free and always will be. Try Pro free for \(days) days — nothing is charged and nothing renews. After that, changing rules is a one-time purchase\(price)."
        }
        if pro.hasTrialEnded {
            return "Your \(days)-day free trial has ended. Reading your rules is still free; changing them is a one-time purchase\(price) — no subscription."
        }
        return "Reading your rules is free and always will be. Changing them is a one-time purchase — no subscription."
    }

    private var trialTitle: String {
        pro.isWorking ? "Working…" : "Start \(days)-day free trial"
    }

    private var buyTitle: String {
        if pro.isWorking { return "Working…" }
        guard let product = pro.product else { return "Unavailable right now" }
        return "Unlock Pro — \(product.displayPrice)"
    }
}
