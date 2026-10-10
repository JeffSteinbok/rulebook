import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// OAuth 2.0 device authorization grant against Microsoft Entra ID.
///
/// This is the flow for the command line: it prints a short code, the user
/// signs in on any browser, and the CLI polls until the token arrives. The
/// iOS app should use MSAL instead and conform its own type to ``TokenProvider``.
///
/// Requires a **public client** app registration with
/// `allowPublicClient: true` (see `Scripts/register-app.sh`).
public actor DeviceCodeTokenProvider: TokenProvider {

    public struct Configuration: Sendable {
        public var clientID: String
        /// `common`, `organizations`, `consumers`, or a tenant GUID/domain.
        public var tenantID: String
        public var scopes: [String]
        /// Where the refresh token is cached. `nil` disables persistence.
        public var cacheURL: URL?

        public init(
            clientID: String,
            tenantID: String = "common",
            scopes: [String] = GraphScopes.default,
            cacheURL: URL? = DeviceCodeTokenProvider.defaultCacheURL
        ) {
            self.clientID = clientID
            self.tenantID = tenantID
            self.scopes = scopes
            self.cacheURL = cacheURL
        }
    }

    /// Details to show the user so they can complete sign-in in a browser.
    public struct DeviceCodePrompt: Sendable {
        public let userCode: String
        public let verificationURI: String
        public let message: String
    }

    /// Where the refresh token is cached, per platform.
    ///
    /// `homeDirectoryForCurrentUser` does not exist on iOS, and a dotfile in
    /// the home directory is a command-line convention anyway — on iOS the
    /// equivalent is Application Support inside the sandbox.
    public static var defaultCacheURL: URL? {
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".rulebook", isDirectory: true)
            .appendingPathComponent("token.json")
        #else
        return try? FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask,
                 appropriateFor: nil, create: true)
            .appendingPathComponent("RuleBook", isDirectory: true)
            .appendingPathComponent("token.json")
        #endif
    }

    private let configuration: Configuration
    private let session: URLSession
    private let prompt: @Sendable (DeviceCodePrompt) -> Void
    /// One second in production; tests shrink it so polling is instant.
    private let pollingUnit: Duration

    private var cached: CachedToken?
    /// The refresh in flight, so concurrent callers share one redemption.
    /// The actor is re-entrant across `await`; without this, two callers can
    /// each redeem the same refresh token.
    private var refreshing: Task<CachedToken, any Error>?

    /// - Parameter prompt: called once with the user code when interactive
    ///   sign-in is needed. Defaults to writing to standard error, which is
    ///   unbuffered — the code has to appear *before* polling starts, and
    ///   buffered stdout would hold it until the process exits.
    public init(
        configuration: Configuration,
        session: URLSession = .shared,
        prompt: @escaping @Sendable (DeviceCodePrompt) -> Void = {
            FileHandle.standardError.write(Data(($0.message + "\n").utf8))
        }
    ) {
        self.init(configuration: configuration, session: session, prompt: prompt, pollingUnit: .seconds(1))
    }

    init(
        configuration: Configuration,
        session: URLSession,
        prompt: @escaping @Sendable (DeviceCodePrompt) -> Void,
        pollingUnit: Duration
    ) {
        self.configuration = configuration
        self.session = session
        self.prompt = prompt
        self.pollingUnit = pollingUnit
    }

    // MARK: - TokenProvider

    /// Never signs in interactively: a library call that blocks for fifteen
    /// minutes waiting on a browser is not something a caller can recover
    /// from. When there is nothing usable, this throws and the caller is told
    /// to run ``signIn()``.
    public func accessToken() async throws -> String {
        // `cached` is empty on a fresh instance, so read the disk cache before
        // deciding anything — otherwise a perfectly valid token is ignored and
        // every call pays for a refresh round trip.
        var token = cached
        if token == nil { token = loadCache() }

        guard let token else { throw RuleStoreError.notAuthenticated }
        if token.isValid { return token.accessToken }

        guard let refreshToken = token.refreshToken else {
            throw RuleStoreError.notAuthenticated
        }

        if let refreshing { return try await refreshing.value.accessToken }
        let task = Task { try await self.redeem(refreshToken: refreshToken) }
        refreshing = task
        defer { refreshing = nil }

        do {
            var refreshed = try await task.value
            // Entra may omit a new refresh token; the old one is still good.
            if refreshed.refreshToken == nil { refreshed.refreshToken = refreshToken }
            store(refreshed)
            return refreshed.accessToken
        } catch AuthError.oauth(let code, _) where Self.needsSignIn.contains(code) {
            // Revoked, expired, or consent withdrawn: the cached token will
            // never work again, so drop it rather than failing the same way
            // on every call.
            signOut()
            throw RuleStoreError.notAuthenticated
        }
    }

    /// OAuth errors that only a fresh interactive sign-in can fix.
    static let needsSignIn: Set<String> = ["invalid_grant", "interaction_required", "consent_required", "login_required"]

    /// Forces a fresh interactive sign-in, ignoring any cached token.
    public func signIn() async throws {
        let token = try await signInWithDeviceCode()
        store(token)
    }

    /// Drops the cached tokens, on disk and in memory.
    public func signOut() {
        cached = nil
        if let cacheURL = configuration.cacheURL {
            try? FileManager.default.removeItem(at: cacheURL)
        }
    }

    // MARK: - Device code flow

    private var authorityURL: URL {
        get throws {
            let tenant = configuration.tenantID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"]))
            guard let tenant, !tenant.isEmpty,
                  let url = URL(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0")
            else { throw AuthError.invalidTenant(configuration.tenantID) }
            return url
        }
    }

    private func signInWithDeviceCode() async throws -> CachedToken {
        let start: DeviceCodeResponse = try await form(
            url: try authorityURL.appendingPathComponent("devicecode"),
            fields: [
                "client_id": configuration.clientID,
                "scope": configuration.scopes.joined(separator: " "),
            ]
        )

        prompt(DeviceCodePrompt(
            userCode: start.userCode,
            verificationURI: start.verificationURI,
            message: start.message
        ))

        let deadline = Date().addingTimeInterval(TimeInterval(start.expiresIn))
        var interval = max(start.interval, 1)

        while Date() < deadline {
            try await Task.sleep(for: pollingUnit * interval)

            let (data, response) = try await postForm(
                url: try authorityURL.appendingPathComponent("token"),
                fields: [
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                    "client_id": configuration.clientID,
                    "device_code": start.deviceCode,
                ]
            )

            if (200..<300).contains(response.statusCode) {
                return try CachedToken(decoding: data)
            }

            let failure = try? JSONDecoder().decode(OAuthError.self, from: data)
            switch failure?.error {
            case "authorization_pending":
                continue
            case "slow_down":
                interval += 5
            default:
                throw AuthError.oauth(
                    code: failure?.error ?? "unknown",
                    description: failure?.errorDescription
                )
            }
        }

        throw AuthError.timedOut
    }

    private func redeem(refreshToken: String) async throws -> CachedToken {
        let (data, response) = try await postForm(
            url: try authorityURL.appendingPathComponent("token"),
            fields: [
                "grant_type": "refresh_token",
                "client_id": configuration.clientID,
                "refresh_token": refreshToken,
                "scope": configuration.scopes.joined(separator: " "),
            ]
        )
        guard (200..<300).contains(response.statusCode) else {
            let failure = try? JSONDecoder().decode(OAuthError.self, from: data)
            throw AuthError.oauth(code: failure?.error ?? "unknown", description: failure?.errorDescription)
        }
        return try CachedToken(decoding: data)
    }

    // MARK: - HTTP

    private func form<T: Decodable>(url: URL, fields: [String: String]) async throws -> T {
        let (data, response) = try await postForm(url: url, fields: fields)
        guard (200..<300).contains(response.statusCode) else {
            let failure = try? JSONDecoder().decode(OAuthError.self, from: data)
            throw AuthError.oauth(code: failure?.error ?? "unknown", description: failure?.errorDescription)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func postForm(url: URL, fields: [String: String]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = fields
            .map { "\($0.key)=\(Self.formEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AuthError.badResponse }
        return (data, http)
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: - Cache

    private func store(_ token: CachedToken) {
        cached = token
        guard let cacheURL = configuration.cacheURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try JSONEncoder().encode(token).write(to: cacheURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
        } catch {
            // A cache write failure is not fatal; the next run just signs in again.
        }
    }

    private func loadCache() -> CachedToken? {
        guard let cacheURL = configuration.cacheURL,
              let data = try? Data(contentsOf: cacheURL),
              let token = try? JSONDecoder().decode(CachedToken.self, from: data)
        else { return nil }
        cached = token
        return token
    }

    // MARK: - Wire types

    struct CachedToken: Codable, Sendable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date

        /// Treated as expired 60s early so a request never races the boundary.
        var isValid: Bool { expiresAt.timeIntervalSinceNow > 60 }

        init(decoding data: Data) throws {
            let response = try JSONDecoder().decode(TokenResponse.self, from: data)
            self.accessToken = response.accessToken
            self.refreshToken = response.refreshToken
            self.expiresAt = Date().addingTimeInterval(TimeInterval(response.expiresIn))
        }
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    private struct DeviceCodeResponse: Decodable {
        let deviceCode: String
        let userCode: String
        let verificationURI: String
        let expiresIn: Int
        let interval: Int
        let message: String

        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code"
            case userCode = "user_code"
            case verificationURI = "verification_uri"
            case expiresIn = "expires_in"
            case interval
            case message
        }
    }

    private struct OAuthError: Decodable {
        let error: String
        let errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
        }
    }

    public enum AuthError: Error, LocalizedError {
        case oauth(code: String, description: String?)
        case timedOut
        case badResponse
        case invalidTenant(String)

        public var errorDescription: String? {
            switch self {
            case .oauth(let code, let description):
                return "Sign-in failed (\(code))\(description.map { ": \($0)" } ?? "")"
            case .timedOut:
                return "Sign-in timed out before the code was entered."
            case .badResponse:
                return "Unexpected response from the sign-in endpoint."
            case .invalidTenant(let tenant):
                return "\u{201C}\(tenant)\u{201D} isn't a tenant: use common, organizations, consumers, a tenant GUID, or a domain."
            }
        }
    }
}
