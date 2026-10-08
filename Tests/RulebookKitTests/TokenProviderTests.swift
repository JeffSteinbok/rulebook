import Foundation
import Testing
@testable import RulebookKit

/// The CLI's sign-in: device code polling, refresh, and the on-disk cache.
@Suite("DeviceCodeTokenProvider", .serialized)
struct TokenProviderTests {

    private func provider(cache: URL?, _ handler: @escaping OAuthStub.Handler) -> DeviceCodeTokenProvider {
        OAuthStub.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OAuthStub.self]
        return DeviceCodeTokenProvider(
            configuration: .init(clientID: "client", tenantID: "common", cacheURL: cache),
            session: URLSession(configuration: configuration),
            prompt: { _ in },
            pollingUnit: .milliseconds(1)
        )
    }

    private func temporaryCache() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("rulebook-token-\(UUID().uuidString)")
            .appendingPathComponent("token.json")
    }

    /// Writes a cache entry the way the provider does: an `expiresAt` in the past forces a refresh.
    private func seedCache(_ url: URL, access: String = "old-access", refresh: String? = "refresh-1", expired: Bool) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var object: [String: Any] = [
            "accessToken": access,
            "expiresAt": Date().addingTimeInterval(expired ? -600 : 3600).timeIntervalSinceReferenceDate,
        ]
        if let refresh { object["refreshToken"] = refresh }
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    static func tokenBody(access: String, refresh: String?) -> String {
        let refreshPart = refresh.map { #","refresh_token":"\#($0)""# } ?? ""
        return #"{"access_token":"\#(access)","expires_in":3600\#(refreshPart)}"#
    }

    @Test("A valid cached token is used with no network at all")
    func cachedTokenNeedsNoNetwork() async throws {
        let cache = temporaryCache()
        try seedCache(cache, access: "cached", expired: false)
        let subject = provider(cache: cache) { _ in Issue.record("No request expected."); return (500, "") }
        #expect(try await subject.accessToken() == "cached")
    }

    @Test("Nothing cached means sign in, not a network call")
    func emptyCacheIsNotAuthenticated() async throws {
        let subject = provider(cache: temporaryCache()) { _ in (500, "") }
        await #expect(throws: RuleStoreError.self) { _ = try await subject.accessToken() }
    }

    @Test("An expired token is refreshed and the new one cached")
    func refreshes() async throws {
        let cache = temporaryCache()
        try seedCache(cache, expired: true)
        let subject = provider(cache: cache) { request in
            #expect(request.form["grant_type"] == "refresh_token")
            #expect(request.form["refresh_token"] == "refresh-1")
            return (200, Self.tokenBody(access: "new-access", refresh: "refresh-2"))
        }
        #expect(try await subject.accessToken() == "new-access")
        let saved = try String(contentsOf: cache, encoding: .utf8)
        #expect(saved.contains("refresh-2"))
    }

    @Test("A refresh that returns no new refresh token keeps the old one")
    func keepsOldRefreshToken() async throws {
        let cache = temporaryCache()
        try seedCache(cache, expired: true)
        let subject = provider(cache: cache) { _ in (200, Self.tokenBody(access: "new-access", refresh: nil)) }
        _ = try await subject.accessToken()
        #expect(try String(contentsOf: cache, encoding: .utf8).contains("refresh-1"))
    }

    @Test("A revoked refresh token means sign in again, and the dead cache is removed", arguments: [
        "invalid_grant", "interaction_required",
    ])
    func revokedRefreshSignsOut(_ code: String) async throws {
        let cache = temporaryCache()
        try seedCache(cache, expired: true)
        let subject = provider(cache: cache) { _ in (400, #"{"error":"\#(code)","error_description":"AADSTS70008"}"#) }
        do {
            _ = try await subject.accessToken()
            Issue.record("Expected notAuthenticated.")
        } catch RuleStoreError.notAuthenticated {}
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }

    @Test("Concurrent callers share one refresh")
    func concurrentRefreshIsShared() async throws {
        let cache = temporaryCache()
        try seedCache(cache, expired: true)
        let counter = Counter()
        let subject = provider(cache: cache) { _ in
            counter.increment()
            Thread.sleep(forTimeInterval: 0.05)
            return (200, Self.tokenBody(access: "new-access", refresh: "refresh-2"))
        }
        async let a = subject.accessToken()
        async let b = subject.accessToken()
        async let c = subject.accessToken()
        let tokens = try await [a, b, c]
        #expect(tokens == ["new-access", "new-access", "new-access"])
        #expect(counter.value == 1)
    }

    @Test("Device code sign-in polls through pending and slow_down, then caches")
    func deviceCodePolling() async throws {
        let cache = temporaryCache()
        let polls = Counter()
        let subject = provider(cache: cache) { request in
            if request.url.path.hasSuffix("devicecode") {
                return (200, #"{"device_code":"dc","user_code":"ABC","verification_uri":"https://microsoft.com/devicelogin","expires_in":600,"interval":1,"message":"Go"}"#)
            }
            polls.increment()
            switch polls.value {
            case 1: return (400, #"{"error":"authorization_pending"}"#)
            case 2: return (400, #"{"error":"slow_down"}"#)
            default: return (200, Self.tokenBody(access: "signed-in", refresh: "r"))
            }
        }
        try await subject.signIn()
        #expect(polls.value == 3)
        #expect(try await subject.accessToken() == "signed-in")
    }

    @Test("A declined sign-in stops polling with the reason")
    func declinedSignIn() async throws {
        let subject = provider(cache: nil) { request in
            if request.url.path.hasSuffix("devicecode") {
                return (200, #"{"device_code":"dc","user_code":"ABC","verification_uri":"https://x","expires_in":600,"interval":1,"message":"Go"}"#)
            }
            return (400, #"{"error":"authorization_declined","error_description":"The user declined."}"#)
        }
        await #expect(throws: DeviceCodeTokenProvider.AuthError.self) { try await subject.signIn() }
    }

    @Test("A tenant that isn't one is an error, not a crash")
    func badTenant() async throws {
        let subject = DeviceCodeTokenProvider(
            configuration: .init(clientID: "client", tenantID: "", cacheURL: nil), prompt: { _ in }
        )
        await #expect(throws: DeviceCodeTokenProvider.AuthError.self) { try await subject.signIn() }
    }

    @Test("Signing out removes the cache file")
    func signOutRemovesCache() async throws {
        let cache = temporaryCache()
        try seedCache(cache, expired: false)
        let subject = provider(cache: cache) { _ in (500, "") }
        await subject.signOut()
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }

    @Test("The cache file is private to the user")
    func cacheIsPrivate() async throws {
        let cache = temporaryCache()
        try seedCache(cache, expired: true)
        let subject = provider(cache: cache) { _ in (200, Self.tokenBody(access: "a", refresh: "r")) }
        _ = try await subject.accessToken()
        let permissions = try FileManager.default.attributesOfItem(atPath: cache.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

/// Answers requests to the sign-in endpoint from a test-supplied handler.
final class OAuthStub: URLProtocol, @unchecked Sendable {
    struct Request {
        let url: URL
        let form: [String: String]
    }
    typealias Handler = @Sendable (Request) -> (Int, String)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: Handler?
    static var handler: Handler? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map { stream -> Data in
            stream.open(); defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            return data
        } ?? Data()
        var form: [String: String] = [:]
        for pair in String(decoding: body, as: UTF8.self).split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            if parts.count == 2 { form[parts[0]] = parts[1] }
        }

        let (status, text) = Self.handler?(Request(url: request.url!, form: form)) ?? (500, "")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
