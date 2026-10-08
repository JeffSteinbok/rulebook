import Foundation
import StoreKit

/// What the user was trying to do when the paywall appeared.
///
/// Carried so the sheet can name the blocked action. "Unlock editing" with no
/// context reads as a toll booth; "Turning a rule off needs Rulebook Pro" reads
/// as an answer to what just happened.
enum PaywallTrigger: String, Identifiable {
    case editing, toggle, delete, reorder, duplicate, bulk

    var id: String { rawValue }

    var headline: String {
        switch self {
        case .editing:   return "Editing rules needs Pro"
        case .toggle:    return "Turning rules on and off needs Pro"
        case .delete:    return "Deleting rules needs Pro"
        case .reorder:   return "Reordering rules needs Pro"
        case .duplicate: return "Duplicating rules needs Pro"
        case .bulk:      return "Changing several rules needs Pro"
        }
    }
}

/// The one entitlement Rulebook sells: everything that writes to the mailbox.
///
/// Reading stays free on purpose. Seeing your real rules in plain language —
/// and being told which ones quietly stopped working — is the thing worth
/// having before anyone pays, and an app whose free tier shows only canned
/// sample data is a paywall with a screenshot behind it.
@MainActor
@Observable
final class ProStore {

    static let productID = "net.steinbok.Rulebook.pro"

    /// A $0 non-consumable named for its length, which is how guideline 3.1.1
    /// lets a one-time-purchase app offer a time-based trial. Claiming it ties
    /// the trial to the Apple Account, so reinstalling doesn't start it over.
    static let trialProductID = "net.steinbok.Rulebook.trial"
    static let trialLength: TimeInterval = 7 * 24 * 60 * 60

    /// Off for launch: Pro is bought or redeemed from an offer code. Flipping
    /// this on also needs the trial product live in App Store Connect.
    static let trialEnabled = false

    /// Bought, or redeemed from an offer code — both land as a transaction for
    /// ``productID``, so a gifted copy needs no special handling.
    private(set) var isPurchased = false

    /// When the claimed trial runs out; nil if it was never claimed.
    private(set) var trialEndsAt: Date?

    private(set) var product: Product?
    private(set) var trialProduct: Product?
    private(set) var isWorking = false
    var errorMessage: String?

    /// Whether writes are allowed. Computed rather than stored so a trial that
    /// lapses mid-session locks at the next write instead of the next launch.
    var isPro: Bool {
        if alwaysUnlocked || isPurchased { return true }
        guard let trialEndsAt else { return false }
        return Date() < trialEndsAt
    }

    var isTrialActive: Bool { !isPurchased && trialEndsAt.map { Date() < $0 } == true }
    var hasTrialEnded: Bool { !isPurchased && trialEndsAt.map { Date() >= $0 } == true }
    var canStartTrial: Bool { !isPurchased && trialEndsAt == nil && trialProduct != nil }

    /// Whole days left, rounded up so the last afternoon reads "1 day", not "0".
    var trialDaysLeft: Int {
        guard let trialEndsAt else { return 0 }
        return max(0, Int((trialEndsAt.timeIntervalSinceNow / 86_400).rounded(.up)))
    }

    /// Nothing was bought — the entitlement is simply not enforced. Used by the
    /// demo seed and previews, where StoreKit isn't running at all.
    private let alwaysUnlocked: Bool

    private var updatesTask: Task<Void, Never>?

    init(alwaysUnlocked: Bool = false) {
        self.alwaysUnlocked = alwaysUnlocked
    }

    // No deinit cancelling `updatesTask`: the store lives for the life of the
    // app, and under Swift 6 a nonisolated deinit can't touch main-actor state
    // anyway. `stop()` exists for tests that need to tear one down.
    func stop() {
        updatesTask?.cancel()
        updatesTask = nil
    }

    var displayPrice: String { product?.displayPrice ?? "" }

    func start() async {
        guard !alwaysUnlocked else { return }

        // Started before the first refresh so a purchase completing elsewhere —
        // Ask to Buy approved later, a restore on another device, or an offer
        // code redeemed in the App Store app — is seen.
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { return }
                guard case .verified(let transaction) = update else { continue }
                await transaction.finish()
                await self.refresh()
            }
        }

        await loadProduct()
        await refresh()
    }

    func loadProduct() async {
        guard !alwaysUnlocked else { return }
        do {
            let ids = Self.trialEnabled ? [Self.productID, Self.trialProductID] : [Self.productID]
            let products = try await Product.products(for: ids)
            product = products.first { $0.id == Self.productID }
            trialProduct = products.first { $0.id == Self.trialProductID }
        } catch {
            // Not surfaced: a missing product means the buy button stays out of
            // the way, and the app is still fully useful for reading.
            product = nil
            trialProduct = nil
        }
    }

    /// Recomputed from StoreKit rather than cached in defaults. `currentEntitlements`
    /// is served from the on-device receipt, so this works with no network —
    /// which matters, because a paid user opening the app on a plane must not
    /// find their app locked.
    ///
    /// The trial's clock runs from the original claim date, which a restore or a
    /// second "purchase" of the same item brings back unchanged — neither resets it.
    func refresh() async {
        guard !alwaysUnlocked else { return }
        var purchased = false
        var trialEnds: Date?
        for await entitlement in Transaction.currentEntitlements {
            guard case .verified(let transaction) = entitlement,
                  transaction.revocationDate == nil else { continue }
            switch transaction.productID {
            case Self.productID:
                purchased = true
            case Self.trialProductID where Self.trialEnabled:
                trialEnds = transaction.originalPurchaseDate.addingTimeInterval(Self.trialLength)
            default:
                break
            }
        }
        isPurchased = purchased
        trialEndsAt = trialEnds
    }

    func startTrial() async {
        guard let trialProduct else { return }
        await purchase(trialProduct)
    }

    func purchase() async {
        guard let product else { return }
        await purchase(product)
    }

    private func purchase(_ product: Product) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    errorMessage = "That purchase couldn't be verified. Nothing was charged."
                    return
                }
                await transaction.finish()
                await refresh()
            case .userCancelled:
                break                       // not an error; say nothing
            case .pending:
                // Ask to Buy, or a payment needing approval. The updates task
                // above is what eventually unlocks it.
                errorMessage = "This purchase is waiting for approval. Rulebook will unlock once it goes through."
            @unknown default:
                break
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Required by App Store guideline 3.1.1, and the most common reason an
    /// in-app purchase is rejected.
    func restore() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        do {
            try await AppStore.sync()
            await refresh()
            if !isPurchased && !isTrialActive {
                errorMessage = "No previous purchase found for this Apple Account."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
