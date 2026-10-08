import SwiftUI
import RulebookKit

@main
struct RulebookApp: App {
    /// Only reason this exists: it installs the scene delegate that hands
    /// Authenticator's callback URL back to MSAL. See MSALResponseHandling.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var accounts = AccountStore()
    @State private var pro = ProStore()
    @State private var tokens: MSALTokenProvider?
    @State private var bootError: String?
    @Environment(\.scenePhase) private var scenePhase

    /// Set in the build settings or an xcconfig; `register-app.sh` prints it.
    private var clientID: String {
        Bundle.main.object(forInfoDictionaryKey: "RulebookClientID") as? String ?? ""
    }

    /// Runs the whole app on `InMemoryRuleStore` with the preview seed: no
    /// MSAL, no network, no Azure. The brief asks for gestures to be judged on
    /// a real touch loop before auth exists, and the seed carries all four
    /// diagnostic states, so this is also how the screenshots get taken.
    private var isDemo: Bool {
        ProcessInfo.processInfo.arguments.contains("-demo")
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if isDemo {
                    RulesListView(model: {
                        let model = RulesListViewModel(
                            store: PreviewSeed.store(),
                            folders: PreviewSeed.folders,
                            profile: ProviderCatalog.outlook
                        )
                        // `-locked` exercises the free tier: same seed, entitlement
                        // enforced. Screenshots use plain `-demo`, which is unlocked.
                        let locked = ProcessInfo.processInfo.arguments.contains("-locked")
                        model.pro = ProStore(alwaysUnlocked: !locked)
                        return model
                    }())
                } else if let tokens {
                    // A connected mailbox means onboarding has nothing to do —
                    // launch straight into the rules.
                    if accounts.isEmpty {
                        GateView(tokens: tokens, accounts: accounts)
                    } else {
                        RootView(tokens: tokens, accounts: accounts)
                    }
                } else if let bootError {
                    BootFailureView(message: bootError)
                } else {
                    ProgressView().task { start() }
                }
            }
            .tint(DS.Palette.accent)
            .environment(pro)
            .task { await pro.start() }
            // A refund, a revocation, or an Ask to Buy approved while Rulebook
            // was in the background shows up when it comes back.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await pro.refresh() } }
            }
        }
    }

    private func start() {
        do {
            tokens = try MSALTokenProvider(clientID: clientID)
        } catch {
            bootError = error.localizedDescription
        }
    }
}

/// Owns the one view model the whole signed-in app shares, so switching
/// mailboxes rebuilds it rather than leaving stale rules on screen.
struct RootView: View {
    let tokens: MSALTokenProvider
    let accounts: AccountStore

    @Environment(ProStore.self) private var pro

    @State private var model: RulesListViewModel?

    var body: some View {
        Group {
            if let model {
                RulesListView(model: model, accounts: accounts, tokens: tokens)
                    // RulesListView holds its model in @State, which SwiftUI
                    // keeps across updates. A new identity per mailbox is what
                    // makes a switch actually show, and write to, the new one.
                    .id(accounts.active?.id)
            } else {
                ProgressView()
            }
        }
        .task(id: accounts.active?.id) { rebuild() }
    }

    private func rebuild() {
        guard let account = accounts.active else { model = nil; return }
        // Pinned to this mailbox's MSAL account, so nothing else can redirect it.
        let mailbox = tokens.tokenProvider(for: account.id)
        // Both stores are `any RuleStore`, so this is the only line that knows
        // the app talks to Graph at all.
        // One folder directory for the store and the list, so the tree is
        // fetched once per mailbox rather than once each.
        let directory = GraphMailFolderDirectory(tokenProvider: mailbox)
        let built = RulesListViewModel(
            store: GraphRuleStore(client: GraphMessageRuleClient(tokenProvider: mailbox), folders: directory),
            folders: directory,
            profile: ProviderCatalog.outlook
        )
        built.pro = pro
        model = built
    }
}

private struct BootFailureView: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rulebook couldn't start")
                .font(DS.Font.sectionTitle)
            Text(message)
                .font(DS.Font.body)
                .foregroundStyle(DS.Palette.ink60)
            Text("Check that RulebookClientID is set in Info.plist and the redirect URI matches the app registration.")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Palette.ink60)
        }
        .padding(DS.Metric.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DS.Palette.ground)
    }
}
