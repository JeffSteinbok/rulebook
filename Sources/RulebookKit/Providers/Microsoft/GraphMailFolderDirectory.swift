import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// ``FolderDirectory`` over Graph's `/me/mailFolders`.
///
/// Walks the whole tree — Graph returns only top-level folders by default, and
/// rules routinely target nested ones — and builds `Parent/Child` paths. The
/// result is cached for the lifetime of the instance, since a rule list
/// typically resolves the same handful of folders repeatedly.
///
/// Needs the `Mail.ReadBasic` scope, which `MailboxSettings.ReadWrite` does not
/// include: folders are a different resource from mailbox settings.
public actor GraphMailFolderDirectory: FolderDirectory {
    private let baseURL: URL
    private let tokenProvider: any TokenProvider
    private let session: URLSession

    private var cache: [MailboxFolder]?
    private var pathByID: [String: String] = [:]

    public init(
        tokenProvider: any TokenProvider,
        baseURL: URL = GraphMessageRuleClient.defaultBaseURL,
        session: URLSession = .shared
    ) {
        self.tokenProvider = tokenProvider
        self.baseURL = baseURL
        self.session = session
    }

    public func folders() async throws -> [MailboxFolder] {
        // Only successes are cached. An earlier version latched failures so a
        // missing scope would not be retried per folder — but that turned one
        // transient error, such as a token arriving late at launch, into an
        // empty folder list for the rest of the session, which is how the
        // rule editor ended up with no folders to pick from.
        if let cache { return cache }
        let raw = try await fetchAll()
        let byID = Dictionary(raw.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Build a display path by walking up parentFolderId. Depth is bounded
        // so a cycle in the data cannot hang the caller.
        func path(for folder: GraphMailFolder) -> String {
            var segments = [folder.displayName]
            var parentID = folder.parentFolderId
            var depth = 0
            while let id = parentID, let parent = byID[id], depth < 16 {
                segments.append(parent.displayName)
                parentID = parent.parentFolderId
                depth += 1
            }
            return segments.reversed().joined(separator: "/")
        }

        var resolved: [MailboxFolder] = []
        for folder in raw {
            let display = path(for: folder)
            pathByID[folder.id] = display
            resolved.append(MailboxFolder(id: folder.id, name: display))
        }
        resolved.sort { ($0.name ?? "") < ($1.name ?? "") }

        cache = resolved
        return resolved
    }

    public func name(forID id: String) async throws -> String? {
        _ = try await folders()
        return pathByID[id]
    }

    public func id(forName name: String) async throws -> String? {
        let all = try await folders()

        // An exact path wins; otherwise fall back to a unique path suffix, so
        // "Reading" and "Newsletters/Tech" resolve without anyone typing the
        // "Inbox/" in front.
        if let exact = all.first(where: { $0.name?.caseInsensitiveCompare(name) == .orderedSame }) {
            return exact.id
        }
        let suffix = "/" + name.lowercased()
        let matches = all.filter { $0.name?.lowercased().hasSuffix(suffix) == true }
        return matches.count == 1 ? matches[0].id : nil
    }

    // MARK: - Fetching

    private func fetchAll() async throws -> [GraphMailFolder] {
        var pending: [String?] = [nil]   // nil == the mailbox root
        var found: [GraphMailFolder] = []

        while let parent = pending.popLast() {
            let path = parent.map { "me/mailFolders/\($0)/childFolders" } ?? "me/mailFolders"
            var next: URL? = baseURL
                .appendingPathComponent(path)
                .appending(queryItems: [
                    URLQueryItem(name: "$top", value: "100"),
                    // Graph omits hidden folders by default, and rules can
                    // target them.
                    URLQueryItem(name: "includeHiddenFolders", value: "true"),
                    URLQueryItem(name: "$select", value: "id,displayName,parentFolderId,childFolderCount"),
                ])

            while let url = next {
                let page: GraphCollection<GraphMailFolder> = try await get(url)
                found.append(contentsOf: page.value)
                // Only descend where Graph says there is something to find.
                pending.append(contentsOf: page.value.filter { ($0.childFolderCount ?? 0) > 0 }.map { $0.id })
                next = page.nextLink.flatMap(URL.init(string:))
            }
        }

        return found
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(try await tokenProvider.accessToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data = try await GraphHTTP.send(request, session: session, retry: .standard)

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw RuleStoreError.decoding(error)
        }
    }
}

struct GraphMailFolder: Decodable, Sendable {
    let id: String
    let displayName: String
    let parentFolderId: String?
    let childFolderCount: Int?
}
