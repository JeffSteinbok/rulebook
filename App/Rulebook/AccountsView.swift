import SwiftUI
import UIKit
import RulebookKit

/// Mailboxes — a list to look at, not a switch.
///
/// Switching lives under the title on the rules list. Here a row opens that
/// mailbox's details, and the active one is labelled rather than ticked, so
/// looking around never changes what the rules list shows. Adding a mailbox,
/// or signing out of the active one, does change it — and returns to the
/// list, since the whole screen is rebuilt for the new mailbox.
struct AccountsView: View {
    let accounts: AccountStore
    let tokens: MSALTokenProvider
    /// Server facts for the active mailbox, passed in so this screen makes no
    /// calls of its own.
    let ruleCount: Int
    let lastSync: Date?

    @State private var isAdding = false

    var body: some View {
        List {
            if accounts.isEmpty {
                Text("No mailbox is connected. Add one and Rulebook will load the rules already running on its server.")
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Palette.ink60)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 20)
                    .listRowBackground(DS.Palette.ground)
            } else {
                ForEach(accounts.accounts) { account in
                    let isActive = accounts.active?.id == account.id
                    // A destination view, not a value plus
                    // `.navigationDestination` — the latter is invisible to
                    // the stack from inside a lazily built List.
                    NavigationLink {
                        AccountDetailView(
                            account: account,
                            isActive: isActive,
                            accounts: accounts,
                            tokens: tokens,
                            ruleCount: isActive ? ruleCount : nil,
                            lastSync: isActive ? lastSync : nil
                        )
                    } label: {
                        accountRow(account, isActive: isActive)
                    }
                    .listRowBackground(DS.Palette.ground)
                    .listRowInsets(.init(top: 0, leading: DS.Metric.gutter, bottom: 0, trailing: DS.Metric.gutter))
                }
            }
        }
        .listStyle(.plain)
        .background(DS.Palette.ground)
        .navigationTitle("Mailboxes")
        .safeAreaInset(edge: .bottom) {
            PrimaryButton(title: "Add account", trailing: "plus") { isAdding = true }
                .padding(.horizontal, DS.Metric.gutter)
                .padding(.vertical, 14)
                .background(.bar)
        }
        .sheet(isPresented: $isAdding) {
            AddAccountView(tokens: tokens, accounts: accounts)
        }
    }

    private func accountRow(_ account: Account, isActive: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(account.displayName)
                    .font(DS.Font.rowTitle)
                    .foregroundStyle(DS.Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(account.address)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.ink60)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if isActive {
                Text("Active")
                    .font(DS.Font.captionBold)
                    .foregroundStyle(DS.Palette.accent700)
            }
        }
        .frame(minHeight: DS.Metric.rowMinHeight)
        .accessibilityElement(children: .combine)
    }
}

/// One mailbox's facts and its sign-out. Opening it doesn't switch to it.
private struct AccountDetailView: View {
    let account: Account
    let isActive: Bool
    let accounts: AccountStore
    let tokens: MSALTokenProvider
    /// Only known for the active mailbox — the one whose rules are loaded.
    let ruleCount: Int?
    let lastSync: Date?

    @State private var confirmSignOut = false
    @State private var signOutFailed = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                listRow { DetailRow(key: "Address", value: account.address) }
                listRow { DetailRow(key: "Server", value: "outlook.office365.com") }
                listRow { DetailRow(key: "Status", value: isActive ? "Active, shown on the rules list" : "Not active") }
                if let ruleCount {
                    listRow { DetailRow(key: "Rules on server", value: String(ruleCount)) }
                    listRow {
                        DetailRow(
                            key: "Last sync",
                            value: lastSync?.formatted(date: .omitted, time: .shortened) ?? "Not synced"
                        )
                    }
                }
            }

            Section {
                Button("Sign out of this mailbox", role: .destructive) {
                    confirmSignOut = true
                }
                .font(DS.Font.rowTitle)
                .frame(minHeight: 56)
                .listRowBackground(DS.Palette.ground)
                .listRowInsets(.init(top: 0, leading: DS.Metric.gutter, bottom: 0, trailing: DS.Metric.gutter))

                Text("Signing out removes Rulebook's access token. The rules stay on the server and keep running.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.ink60)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 12)
                    .listRowBackground(DS.Palette.ground)
            }
        }
        .listStyle(.plain)
        .background(DS.Palette.ground)
        .navigationTitle(account.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Sign out of \(account.address)?",
            isPresented: $confirmSignOut,
            titleVisibility: .visible
        ) {
            Button("Sign out", role: .destructive) {
                // This mailbox's tokens only, never whichever MSAL touched last.
                Task {
                    do {
                        try await tokens.signOut(accountID: account.id)
                    } catch {
                        // Keep the mailbox: removing it while its token stays
                        // in the Keychain would claim a sign-out that didn't
                        // happen, and re-adding it would skip the sign-in.
                        DiagnosticsLog.shared.append("sign-out failed: \((error as NSError).domain) \((error as NSError).code)")
                        signOutFailed = true
                        return
                    }
                    accounts.remove(account)
                    dismiss()
                }
            }
        }
        .alert("Couldn't sign out", isPresented: $signOutFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Rulebook couldn't remove this mailbox's token from the phone, so it's still signed in. Try again, or restart the phone and try again.")
        }
    }

    /// The list-row chrome every detail row shares.
    private func listRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .listRowBackground(DS.Palette.ground)
            .listRowInsets(.init(top: 0, leading: DS.Metric.gutter, bottom: 0, trailing: DS.Metric.gutter))
    }
}

// MARK: - About

/// App info only. Mailbox facts live on the Mailboxes screen.
struct AboutView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    private static let supportURL = URL(string: "https://rulebook.steinbok.net/support.html")!

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        // The build is a timestamp: 20260906.2020 is 6 Sep 2026, 20:20 UTC.
        // Rendered as a date so it reads as one.
        let stamp = build.split(separator: ".")
        if stamp.count == 2, stamp[0].count == 8 {
            let d = stamp[0], t = stamp[1]
            return "\(short) (\(d.prefix(4))-\(d.dropFirst(4).prefix(2))-\(d.suffix(2)) \(t.prefix(2)):\(t.suffix(2)))"
        }
        return "\(short) (build \(build))"
    }

    var body: some View {
        List {
            Section {
                let header = typeSize >= .accessibility1
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                    : AnyLayout(HStackLayout(alignment: .center, spacing: 16))
                header {
                    // The app icon — the one place inside the app it appears,
                    // so About matches what's on the home screen.
                    Image("AppLogo")
                        .resizable()
                        .frame(width: 72, height: 72)
                        .clipShape(.rect(cornerRadius: 16, style: .continuous))
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Rulebook")
                            .font(DS.Font.display)
                        // Two set lines, like the splash screen.
                        Text("Outlook mail rules,\nmanaged on mobile.")
                            .font(DS.Font.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.bottom, 12)
                .listRowBackground(DS.Palette.ground)
            }

            Section {
                // Long-press to copy: a build stamp and a support URL are
                // exactly what a bug report needs, and reading them off the
                // screen by hand is where they get transcribed wrong.
                DetailRow(key: "Version", value: version)
                    .copyable(version, label: "Copy version")
                    .listRowBackground(DS.Palette.ground)
                    .listRowInsets(.init(top: 0, leading: DS.Metric.gutter, bottom: 0, trailing: DS.Metric.gutter))

                Link(destination: Self.supportURL) {
                    DetailRow(key: "Support", value: "https://rulebook.steinbok.net/support.html", isLink: true)
                }
                .copyable(Self.supportURL.absoluteString, label: "Copy link")
                .listRowBackground(DS.Palette.ground)
                .listRowInsets(.init(top: 0, leading: DS.Metric.gutter, bottom: 0, trailing: DS.Metric.gutter))

                // NavigationLink with a destination view, not a value plus a
                // `.navigationDestination`: the latter is invisible to the
                // stack when declared inside a lazily built List, which is the
                // same trap called out on the rules list.
                NavigationLink {
                    DiagnosticsView()
                } label: {
                    DetailRow(key: "Diagnostics", value: "Share a log")
                }
                .listRowBackground(DS.Palette.ground)
                .listRowInsets(.init(top: 0, leading: DS.Metric.gutter, bottom: 0, trailing: DS.Metric.gutter))
            }

            Section {
                Text("Rulebook never stores your mail. It reads and writes the rules on your mail server, and those rules keep running when the app is closed.")
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Palette.ink60)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 16)
                    .listRowBackground(DS.Palette.ground)
            }
        }
        .listStyle(.plain)
        .background(DS.Palette.ground)
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Text("Made with ♥ by Jeff Steinbok")
                .font(DS.Font.captionBold)
                .foregroundStyle(DS.Palette.ink80)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Metric.gutter)
                .padding(.vertical, 14)
                .background(.bar)
        }
    }
}

#Preview("About") {
    NavigationStack { AboutView() }
}


// MARK: - Copy affordance

private extension View {
    /// Long-press to copy the row's value.
    ///
    /// `.textSelection` is the obvious reach here and the wrong one: inside a
    /// `List` row it swallows the row's own tap, which would cost the Support
    /// row its link. A context menu leaves the tap alone.
    func copyable(_ value: String, label: String) -> some View {
        contextMenu {
            Button {
                UIPasteboard.general.string = value
            } label: {
                Label(label, systemImage: "doc.on.doc")
            }
        }
    }
}
