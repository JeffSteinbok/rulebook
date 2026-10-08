import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The Microsoft Graph wire layer: HTTP and JSON only, speaking Graph's own
/// `messageRule` type.
///
/// ``GraphRuleStore`` wraps this with ``GraphRuleMapper`` to expose the
/// neutral ``MailRule`` model. Use this directly only when you need something
/// Graph-specific that the neutral model cannot express.
///
/// Endpoint: `/me/mailFolders/inbox/messageRules` — Graph exposes message
/// rules on the Inbox only.
public struct GraphMessageRuleClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://graph.microsoft.com/v1.0")!

    private let baseURL: URL
    private let tokenProvider: any TokenProvider
    private let session: URLSession
    private let retryPolicy: RetryPolicy

    public init(
        tokenProvider: any TokenProvider,
        baseURL: URL = GraphMessageRuleClient.defaultBaseURL,
        session: URLSession = .shared,
        retryPolicy: RetryPolicy = .standard
    ) {
        self.tokenProvider = tokenProvider
        self.baseURL = baseURL
        self.session = session
        self.retryPolicy = retryPolicy
    }

    /// How throttling (429) and brief outages (503, 504) are retried.
    public struct RetryPolicy: Sendable {
        /// Retries after the first attempt.
        public var attempts: Int
        /// Used when Graph sends no `Retry-After`.
        public var defaultDelay: Duration
        /// A `Retry-After` longer than this is not waited out; the error surfaces.
        public var longestDelay: Duration

        public init(attempts: Int, defaultDelay: Duration, longestDelay: Duration) {
            self.attempts = attempts
            self.defaultDelay = defaultDelay
            self.longestDelay = longestDelay
        }

        public static let standard = RetryPolicy(attempts: 2, defaultDelay: .seconds(1), longestDelay: .seconds(10))
        public static let none = RetryPolicy(attempts: 0, defaultDelay: .zero, longestDelay: .zero)
    }

    private var rulesURL: URL {
        baseURL.appendingPathComponent("me/mailFolders/inbox/messageRules")
    }

    // MARK: - CRUD

    public func listRules() async throws -> [MessageRule] {
        // Graph pages this collection; follow @odata.nextLink until it stops.
        var url: URL? = rulesURL
        var all: [MessageRule] = []

        while let next = url {
            let page: GraphCollection<MessageRule> = try await send(
                request(.get, url: next),
                expecting: GraphCollection<MessageRule>.self
            )
            all.append(contentsOf: page.value)
            url = page.nextLink.flatMap(URL.init(string:))
        }

        return all.sorted { ($0.sequence ?? .max, $0.displayName) < ($1.sequence ?? .max, $1.displayName) }
    }

    public func rule(id: String) async throws -> MessageRule {
        do {
            return try await send(
                request(.get, url: rulesURL.appendingPathComponent(id)),
                expecting: MessageRule.self
            )
        } catch let RuleStoreError.provider(_, status, _, _) where status == 404 {
            throw RuleStoreError.notFound(id: id)
        }
    }

    public func createRule(_ rule: MessageRule) async throws -> MessageRule {
        var req = try await request(.post, url: rulesURL)
        req.httpBody = try Self.encoder.encode(rule.writablePayload())
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(req, expecting: MessageRule.self)
    }

    public func updateRule(id: String, with rule: MessageRule) async throws -> MessageRule {
        var req = try await request(.patch, url: rulesURL.appendingPathComponent(id))
        req.httpBody = try Self.encoder.encode(rule.writablePayload())
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            return try await send(req, expecting: MessageRule.self)
        } catch let RuleStoreError.provider(_, status, _, _) where status == 404 {
            throw RuleStoreError.notFound(id: id)
        }
    }

    /// Moves a rule to `sequence` and nothing else. Graph shifts the rules it
    /// displaces, so one request is a whole reorder, and no other field of
    /// the rule is rewritten from a possibly stale copy.
    public func moveRule(id: String, toSequence sequence: Int) async throws -> MessageRule {
        var req = try await request(.patch, url: rulesURL.appendingPathComponent(id))
        req.httpBody = try JSONSerialization.data(withJSONObject: ["sequence": sequence])
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            return try await send(req, expecting: MessageRule.self)
        } catch let RuleStoreError.provider(_, status, _, _) where status == 404 {
            throw RuleStoreError.notFound(id: id)
        }
    }

    public func deleteRule(id: String) async throws {
        let req = try await request(.delete, url: rulesURL.appendingPathComponent(id))
        do {
            try await sendIgnoringBody(req)
        } catch let RuleStoreError.provider(_, status, _, _) where status == 404 {
            throw RuleStoreError.notFound(id: id)
        }
    }

    // MARK: - Plumbing

    private enum Method: String { case get = "GET", post = "POST", patch = "PATCH", delete = "DELETE" }

    static let encoder = JSONEncoder()
    static let decoder = JSONDecoder()

    private func request(_ method: Method, url: URL) async throws -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method.rawValue
        req.setValue("Bearer \(try await tokenProvider.accessToken())", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    private func send<T: Decodable>(_ request: URLRequest, expecting: T.Type) async throws -> T {
        let data = try await validated(request)
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw RuleStoreError.decoding(error)
        }
    }

    private func sendIgnoringBody(_ request: URLRequest) async throws {
        _ = try await validated(request)
    }

    private func validated(_ request: URLRequest) async throws -> Data {
        try await GraphHTTP.send(request, session: session, retry: retryPolicy)
    }
}

// MARK: - Graph wire envelopes

struct GraphCollection<Element: Decodable>: Decodable {
    let value: [Element]
    let nextLink: String?

    private enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
    }
}

/// Sending, status handling and retries, shared by every Graph caller.
enum GraphHTTP {
    static func send(_ request: URLRequest, session: URLSession, retry: GraphMessageRuleClient.RetryPolicy) async throws -> Data {
        var attempt = 0
        while true {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                throw RuleStoreError.transport(error)
            }

            guard let http = response as? HTTPURLResponse else {
                throw RuleStoreError.provider(.microsoft, status: -1, code: nil, message: "Non-HTTP response.")
            }
            if (200..<300).contains(http.statusCode) { return data }

            if [429, 503, 504].contains(http.statusCode), attempt < retry.attempts {
                let delay = retryAfter(http) ?? retry.defaultDelay
                if delay <= retry.longestDelay {
                    attempt += 1
                    try await Task.sleep(for: delay)
                    continue
                }
            }

            let error = try? JSONDecoder().decode(GraphErrorEnvelope.self, from: data)
            // An expired or revoked token: the caller has to sign in again,
            // which is a different remedy from any other failure.
            if http.statusCode == 401 { throw RuleStoreError.notAuthenticated }
            throw RuleStoreError.provider(
                .microsoft,
                status: http.statusCode,
                code: error?.error.code,
                message: error?.error.message
            )
        }
    }

    /// `Retry-After` in seconds. Graph does not send the HTTP-date form.
    private static func retryAfter(_ response: HTTPURLResponse) -> Duration? {
        (response.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init).map { .milliseconds(Int($0 * 1000)) }
    }
}

struct GraphErrorEnvelope: Decodable {
    struct Payload: Decodable {
        let code: String?
        let message: String?
    }
    let error: Payload
}
