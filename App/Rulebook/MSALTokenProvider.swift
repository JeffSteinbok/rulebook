import Foundation
import MSAL
import RulebookKit

/// The only MSAL-aware type in the app.
///
/// `RulebookKit` imports nothing but Foundation and takes its bearer token
/// through `TokenProvider` — so MSAL stops here and never reaches the library
/// or the view models.
///
/// Authority is `common`, not the registration's tenant GUID:
/// `Scripts/register-app.sh` prints the sign-in authority for this reason, and
/// pinning a tenant locks out personal Microsoft accounts.
///
/// There is no "current account" here. Each mailbox's store gets its own
/// ``AccountTokenProvider`` from ``tokenProvider(for:)``, pinned to one MSAL
/// account. That way switching mailboxes, signing one out, or a re-sign-in
/// prompt can never point one mailbox's store at another's tokens.
actor MSALTokenProvider {

    enum AuthError: LocalizedError {
        case noAccount
        case signInRequired
        case cancelled
        case interactionRequired
        case offline
        case failed(domain: String, code: Int)

        var errorDescription: String? {
            switch self {
            case .noAccount: "No mailbox is connected."
            case .signInRequired: "Microsoft needs you to sign in to this mailbox again."
            case .cancelled: "Sign-in was cancelled."
            case .interactionRequired: "Please sign in again."
            case .offline: "Rulebook couldn't reach Microsoft. Check your connection and try again."
            case let .failed(domain, code):
                // Naming the domain and code is not decoration: MSAL collapses
                // most failures into MSALErrorInternal (-50000) with an empty
                // description, so this is the only part of the message that
                // distinguishes one from another in a bug report.
                "Sign-in failed (\(domain) \(code)). About → Diagnostics has the log."
            }
        }

        /// Turns whatever MSAL threw into something a tester can report.
        ///
        /// Passing `localizedDescription` straight to the UI is what made a
        /// genuine network drop and a broker failure look identical. A real
        /// `NSURLErrorDomain` failure is the one case that can be named
        /// outright; everything else at least carries its domain and code.
        static func describing(_ error: Error) -> AuthError {
            if let authError = error as? AuthError { return authError }

            let error = error as NSError
            DiagnosticsLog.shared.append(
                "auth failure: \(error.domain) \(error.code) \(error.localizedDescription)"
            )

            if error.domain == NSURLErrorDomain { return .offline }
            return .failed(domain: error.domain, code: error.code)
        }
    }

    private let application: MSALPublicClientApplication
    private let scopes: [String]

    /// MSAL reports almost everything as MSALErrorInternal (-50000), whose
    /// `localizedDescription` says nothing. Its own logger is the only place
    /// the real reason appears, so it is wired up once, here.
    private static let logging: Void = {
        // On a device, brokered auth is what you want: sign-in goes to the
        // Microsoft Authenticator app, which is how most managed tenants expect
        // it to work and gives SSO with other Microsoft apps.
        //
        // The simulator has no Authenticator, and MSAL will not fall back on
        // its own — it fails before any browser opens:
        //   "Requiring default broker type due to app being built with iOS 13 SDK"
        //   Encountered error with code -51112
        // surfacing as the useless MSALErrorInternal (-50000). So the broker is
        // disabled there and only there. ASWebAuthenticationSession still runs
        // Microsoft's own page either way, so the app never sees a password.
        #if targetEnvironment(simulator)
        MSALGlobalConfig.brokerAvailability = .none
        #endif

        // Masking off is what makes a local failure explicable: without it every
        // description logs as "Masked(not-null)", which is how two failures in
        // a row went unexplained. It stays a debug-only setting — a release
        // build reaches testers, and the log is now shareable from About →
        // Diagnostics, so anything unmasked here would leave the device.
        #if DEBUG
        MSALGlobalConfig.loggerConfig.logLevel = .verbose
        MSALGlobalConfig.loggerConfig.logMaskingLevel = .settingsMaskSecretsOnly
        #else
        MSALGlobalConfig.loggerConfig.logLevel = .info
        MSALGlobalConfig.loggerConfig.logMaskingLevel = .settingsMaskAllPII
        #endif

        MSALGlobalConfig.loggerConfig.setLogCallback { _, message, containsPII in
            guard let message else { return }
            // Belt and braces: masking should already have cleared these in a
            // release build, so a line still flagged as PII is one MSAL did not
            // expect to mask. It is not worth shipping to a bug report.
            #if !DEBUG
            if containsPII { return }
            #endif
            DiagnosticsLog.shared.append(message)
            NSLog("MSALLOG %@", message)
        }
    }()

    /// MSAL requests these itself and refuses the call if they are passed in:
    ///   "{( openid, profile, offline_access )} are reserved scopes and may not
    ///    be specified in the acquire token call."
    /// `GraphScopes.default` names `offline_access` because the CLI's raw
    /// device-code flow has to ask for it explicitly. MSAL does not.
    private static let reservedScopes: Set<String> = ["openid", "profile", "offline_access"]

    init(clientID: String, scopes: [String] = GraphScopes.default) throws {
        _ = Self.logging

        let authority = try MSALAuthority(
            url: URL(string: "https://login.microsoftonline.com/common")!
        )
        let config = MSALPublicClientApplicationConfig(
            clientId: clientID,
            redirectUri: nil,          // msauth.<bundle-id>://auth, from Info.plist
            authority: authority
        )

        // MSAL defaults its token cache to the shared `com.microsoft.adalcache`
        // keychain group, which needs a keychain-sharing entitlement — and that
        // entitlement cannot resolve under the simulator's ad-hoc signature,
        // where $(AppIdentifierPrefix) expands to nothing. Every call then fails
        // as MSALErrorInternal (-50000), with the real reason only in the device
        // log. Keeping the cache in the app's own group avoids the entitlement
        // entirely; the shared group only exists to enable SSO with other
        // Microsoft apps, which this app does not do.
        config.cacheConfig.keychainSharingGroup = Bundle.main.bundleIdentifier ?? clientID

        self.application = try MSALPublicClientApplication(configuration: config)
        self.scopes = scopes.filter { !Self.reservedScopes.contains($0.lowercased()) }
    }

    /// Who signed in: MSAL's stable key (the `Account.id`) and the address.
    struct SignedIn: Sendable {
        let identifier: String
        let address: String
    }

    /// A token source for one mailbox and only that mailbox.
    nonisolated func tokenProvider(for accountID: String) -> AccountTokenProvider {
        AccountTokenProvider(source: self, accountID: accountID)
    }

    /// The MSAL account behind a mailbox's `Account.id`. 1.0 stored the
    /// address as the id when MSAL gave no identifier, so an address matches too.
    ///
    /// Logged rather than swallowed: an unreadable cache and an empty one both
    /// end in a sign-in prompt, but only the log says which it was.
    private func msalAccount(_ accountID: String) -> MSALAccount? {
        if let account = try? application.account(forIdentifier: accountID) { return account }
        do {
            return try application.allAccounts().first {
                $0.username?.caseInsensitiveCompare(accountID) == .orderedSame
            }
        } catch {
            DiagnosticsLog.shared.append("token cache unreadable: \((error as NSError).domain) \((error as NSError).code)")
            return nil
        }
    }

    // MARK: - Tokens

    /// Silent only. The app should never see a login screen on a warm launch.
    ///
    /// The app's mailbox list and MSAL's token cache are stored apart, and can
    /// disagree: a new phone restored from backup brings the list back without
    /// the keychain tokens, and a prewarmed launch can run before first unlock,
    /// when the keychain can't be read. The cache is read fresh on every call,
    /// and when it has nothing for this mailbox the answer is "sign-in needed".
    ///
    /// Never interactive from here: the first call comes from the rules list
    /// loading at launch, before the scene is active, so there's no window to
    /// present on and it failed as "Sign-in was cancelled". The list offers a
    /// Sign in button instead (``signInAgain(accountID:)``), which only runs
    /// from a tap.
    func accessToken(for accountID: String) async throws -> String {
        guard let account = msalAccount(accountID) else {
            DiagnosticsLog.shared.append("no cached account; sign-in required")
            throw AuthError.signInRequired
        }

        do {
            let params = MSALSilentTokenParameters(scopes: scopes, account: account)
            return try await withCheckedThrowingContinuation { continuation in
                application.acquireTokenSilent(with: params) { result, error in
                    if let result { continuation.resume(returning: result.accessToken) }
                    else { continuation.resume(throwing: error ?? AuthError.interactionRequired) }
                }
            }
        } catch let error as NSError where error.code == MSALError.interactionRequired.rawValue {
            // Same reason as above: this can run at launch, with no window.
            throw AuthError.signInRequired
        } catch {
            throw AuthError.describing(error)
        }
    }

    // MARK: - Interactive

    /// Presents `ASWebAuthenticationSession` via MSAL's webview parameters, so
    /// Microsoft's own page handles the password, MFA, conditional access and
    /// consent. The app never renders a credential field.
    @MainActor
    private func presentationAnchor() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
        guard var anchor = scene?.keyWindow?.rootViewController else { return nil }

        // Sign-in is reached from inside the Add-account sheet, so the root
        // controller already has something presented on it and cannot present
        // again. Walk to whatever is actually on top.
        while let presented = anchor.presentedViewController {
            anchor = presented
        }
        return anchor
    }

    /// Signs a mailbox back in, from a tap. Pinned to that mailbox when MSAL
    /// still knows it, so Microsoft's page can't hand back a different one.
    /// When MSAL has lost it entirely (a restored phone), the page asks, and
    /// the caller decides what to do if someone else signs in.
    func signInAgain(accountID: String) async throws -> SignedIn {
        let result = try await interactive(account: msalAccount(accountID))
        guard let identifier = result.account.identifier else {
            throw AuthError.failed(domain: "MSAL", code: -1)
        }
        return SignedIn(identifier: identifier, address: result.account.username ?? "")
    }

    /// Adds a mailbox: Microsoft's page asks which account.
    func signIn() async throws -> SignedIn {
        let result = try await interactive(account: nil)
        guard let identifier = result.account.identifier else {
            throw AuthError.failed(domain: "MSAL", code: -1)
        }
        return SignedIn(identifier: identifier, address: result.account.username ?? "")
    }

    private func interactive(account: MSALAccount?) async throws -> MSALResult {
        // No window to present over (the app is in the background): this is
        // not the person cancelling, it's "sign in again when you're back".
        guard let anchor = await presentationAnchor() else { throw AuthError.cancelled }

        let webParams = MSALWebviewParameters(authPresentationViewController: anchor)
        // .default routes to ASWebAuthenticationSession, which shares the
        // system cookie jar — so an existing Outlook session signs in silently.
        webParams.webviewType = .default

        let params = MSALInteractiveTokenParameters(scopes: scopes, webviewParameters: webParams)
        if let account {
            // Re-sign-in: pinned to the mailbox that needs it.
            params.account = account
            params.promptType = .default
        } else {
            // No loginHint: .selectAccount makes Microsoft's own page ask which
            // mailbox, so the app never has to collect an address up front.
            params.promptType = .selectAccount
        }

        let result: MSALResult = try await withCheckedThrowingContinuation { continuation in
            application.acquireToken(with: params) { result, error in
                if let result { continuation.resume(returning: result) }
                else if let error = error as NSError?,
                        error.code == MSALError.userCanceled.rawValue {
                    continuation.resume(throwing: AuthError.cancelled)
                } else {
                    continuation.resume(throwing: AuthError.describing(error ?? AuthError.interactionRequired))
                }
            }
        }

        return result
    }

    /// Forgets one mailbox's tokens; the others are untouched. The rules stay
    /// on the server and keep running.
    func signOut(accountID: String) throws {
        guard let account = msalAccount(accountID) else { return }
        try application.remove(account)
    }
}

/// One mailbox's tokens. What a `GraphRuleStore` is built on.
struct AccountTokenProvider: TokenProvider {
    let source: MSALTokenProvider
    let accountID: String

    func accessToken() async throws -> String {
        try await source.accessToken(for: accountID)
    }
}
