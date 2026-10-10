import SwiftUI
import RulebookKit

/// Add a mailbox: an explainer, then Microsoft's own sign-in, then a summary.
///
/// Two app screens with a system-owned one between them. Microsoft handles the
/// address, password, MFA, conditional access and the consent grant — this view
/// collects nothing itself, and there is no provider step while Outlook is the
/// only live option.
struct AddAccountView: View {
    let tokens: MSALTokenProvider
    let accounts: AccountStore

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .explainer
    @State private var isAuthenticating = false
    @State private var connected: Account?
    @State private var ruleCount: Int?
    @State private var errorMessage: String?

    private enum Phase { case explainer, done }

    var body: some View {
        NavigationStack {
            List {
                switch phase {
                case .explainer: explainer
                case .done: summary
                }
            }
            .listStyle(.plain)
            .background(DS.Palette.ground)
            .navigationTitle(phase == .explainer ? "Add account" : "Connected")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(phase == .done ? "Back" : "Cancel") {
                        if phase == .done { phase = .explainer } else { dismiss() }
                    }
                    .font(DS.Font.secondary)
                }
            }
            .safeAreaInset(edge: .bottom) { footer }
            .alert("Couldn't connect", isPresented: errorBinding) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: - Explainer

    private var explainer: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("Connect your Outlook mailbox")
                    .font(DS.Font.sectionTitle)
                Text("Microsoft runs the whole sign-in — you'll enter the mailbox address and password on their page. Rulebook never sees your password; it receives a token you can revoke at any time.")
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Palette.ink60)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 8)
            .listRowBackground(DS.Palette.ground)

            ForEach(Self.scopes, id: \.title) { scope in
                VStack(alignment: .leading, spacing: 4) {
                    Text(scope.title)
                        .font(DS.Font.rowTitle)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(scope.detail)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Palette.ink60)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 14)
                .accessibilityElement(children: .combine)
                .listRowBackground(DS.Palette.ground)
                .listRowInsets(.init(top: 0, leading: DS.Metric.gutter, bottom: 0, trailing: DS.Metric.gutter))
            }

            Text("You'll approve these on Microsoft's own consent screen in the next step.")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Palette.ink60)
                .padding(.vertical, 16)
                .listRowBackground(DS.Palette.ground)
        } header: {
            SectionHeader(text: "What Rulebook will ask for")
        }
    }

    /// Worded from `GraphScopes.default`. Deliberately does *not* claim
    /// "never message bodies" — `Mail.ReadBasic` grants sender, recipients and
    /// subject for every message, and the copy must not overclaim.
    private static let scopes: [(title: String, detail: String)] = [
        ("Read your mail rules",
         "So the list can show what's already running on the server."),
        ("Create and change rules",
         "Only when you save a rule yourself."),
        ("Read your folder names",
         "So a rule can file mail into a folder you already have."),
    ]

    // MARK: - Summary

    @ViewBuilder
    private var summary: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("MAILBOX CONNECTED")
                    .font(DS.Font.sectionHeader)
                    .tracking(DS.Metric.sectionTracking)
                    .foregroundStyle(DS.Palette.accent700)
                Text(connected?.address ?? "")
                    .font(DS.Font.sectionTitle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 8)
            .listRowBackground(DS.Palette.ground)

            listRow { DetailRow(key: "Server", value: "outlook.office365.com") }
            listRow { DetailRow(key: "Rules found", value: ruleCount.map(String.init) ?? "—") }
            listRow { DetailRow(key: "Access", value: "Revocable token") }

            Text("These rules were already running on the server. Nothing has been changed — open the list to review them.")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Palette.ink60)
                .padding(.vertical, 16)
                .listRowBackground(DS.Palette.ground)
        }
    }

    private func listRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .listRowBackground(DS.Palette.ground)
            .listRowInsets(.init(top: 0, leading: DS.Metric.gutter, bottom: 0, trailing: DS.Metric.gutter))
    }

    // MARK: - Footer

    private var footer: some View {
        PrimaryButton(
            title: phase == .explainer ? "Sign in with Microsoft" : "Open my rules",
            trailing: isAuthenticating ? nil : "arrow.right"
        ) {
            Task { await proceed() }
        }
        .disabled(isAuthenticating)
        .opacity(isAuthenticating ? 0.6 : 1)
        .padding(.horizontal, DS.Metric.gutter)
        .padding(.vertical, 14)
        .background(.bar)
    }

    private func proceed() async {
        guard phase == .explainer else { dismiss(); return }

        isAuthenticating = true
        defer { isAuthenticating = false }

        do {
            // Presents ASWebAuthenticationSession. Everything inside is
            // Microsoft's — the address prompt included, and Cancel, which
            // throws .cancelled. The address comes back on the account.
            let signedIn = try await tokens.signIn()
            guard !signedIn.address.isEmpty else {
                errorMessage = "Signed in, but no account came back."
                return
            }

            let account = Account(
                id: signedIn.identifier,
                address: signedIn.address,
                displayName: Account.displayName(for: signedIn.address)
            )

            // Read once before showing the summary, so "rules found" is real.
            let store = GraphRuleStore(tokenProvider: tokens.tokenProvider(for: account.id))
            ruleCount = (try? await store.listRules().count)

            accounts.add(account)
            connected = account
            phase = .done
        } catch MSALTokenProvider.AuthError.cancelled {
            // Silent return: the user chose to back out.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }
}

// MARK: - Gate

/// Shown only when no mailbox is connected. Someone with an account never
/// reaches this screen — the app shell launches straight into the rules list.
struct GateView: View {
    let tokens: MSALTokenProvider
    let accounts: AccountStore

    @State private var isAdding = false
    @State private var showingAbout = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer()

            Text("RULEBOOK")
                .font(.custom("Archivo-Black", size: 68, relativeTo: .largeTitle))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .accessibilityLabel("Rulebook")

            Rectangle()
                .fill(.white)
                .frame(width: 56, height: 3)

            Text("Outlook mail rules — managed on mobile.")
                .font(.custom("Archivo-Regular", size: 22, relativeTo: .title3))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 280, alignment: .leading)

            Spacer()

            VStack(spacing: 12) {
                Button("Add account") { isAdding = true }
                    .buttonStyle(GateButtonStyle(filled: true))

                Button("About Rulebook") { showingAbout = true }
                    .buttonStyle(GateButtonStyle(filled: false))

                Divider().overlay(.white.opacity(0.5))

                Text("Made with ♥ by Jeff Steinbok")
                    .font(DS.Font.captionBold)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, minHeight: 0, alignment: .leading)
        .background(DS.Palette.accent)
        .modifier(ScrollableIfNeeded())
        .sheet(isPresented: $isAdding) {
            AddAccountView(tokens: tokens, accounts: accounts)
        }
        .sheet(isPresented: $showingAbout) {
            NavigationStack { AboutView() }
        }
    }
}

/// The gate is a full-bleed poster, which stops fitting at large type sizes.
private struct ScrollableIfNeeded: ViewModifier {
    func body(content: Content) -> some View {
        ScrollView {
            content.frame(minHeight: UIScreen.main.bounds.height - 40)
        }
        .background(DS.Palette.accent)
        .scrollBounceBehavior(.basedOnSize)
    }
}

private struct GateButtonStyle: ButtonStyle {
    let filled: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
                .font(DS.Font.button)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            Image(systemName: filled ? "arrow.right" : "chevron.right")
        }
        .foregroundStyle(filled ? DS.Palette.accent : .white)
        .padding(.horizontal, DS.Metric.gutter)
        .padding(.vertical, 12)
        .frame(minHeight: filled ? 56 : 48)
        .background {
            if filled {
                RoundedRectangle(cornerRadius: DS.Metric.controlRadius)
                    .fill(.white.opacity(configuration.isPressed ? 0.72 : 1))
            } else {
                // The outlined variant is white-on-accent, where the old
                // blanket 0.85 opacity dip was invisible — "About Rulebook"
                // read as a dead control. It needs a fill to react at all.
                RoundedRectangle(cornerRadius: DS.Metric.controlRadius)
                    .fill(.white.opacity(configuration.isPressed ? 0.25 : 0))
                    .overlay {
                        RoundedRectangle(cornerRadius: DS.Metric.controlRadius)
                            .strokeBorder(.white.opacity(0.6), lineWidth: 1)
                    }
            }
        }
        // The outlined button's interior is transparent; without this only the
        // label and border are tappable, not the box.
        .contentShape(RoundedRectangle(cornerRadius: DS.Metric.controlRadius))
        .scaleEffect(configuration.isPressed ? 0.98 : 1)
        .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
