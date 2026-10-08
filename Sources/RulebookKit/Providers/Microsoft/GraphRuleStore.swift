import Foundation

/// The Microsoft 365 ``RuleStore``: ``GraphMessageRuleClient`` for the wire,
/// ``GraphRuleMapper`` for the translation.
///
/// Everything above this speaks ``MailRule``; nothing above it needs to know
/// Graph exists.
///
/// Given a ``FolderDirectory``, the store also resolves folder references in
/// both directions — opaque Graph ids become readable paths on the way out,
/// and a folder named by a person becomes an id on the way in. Resolution is
/// best-effort: if `Mail.ReadBasic` has not been consented, rules still load
/// and show their raw ids.
public struct GraphRuleStore: RuleStore {
    public let capabilities = GraphRuleMapper.capabilities

    private let client: GraphMessageRuleClient
    private let mapper = GraphRuleMapper()
    private let directory: (any FolderDirectory)?

    public init(client: GraphMessageRuleClient, folders directory: (any FolderDirectory)? = nil) {
        self.client = client
        self.directory = directory
    }

    /// - Parameter resolveFolderNames: builds a ``GraphMailFolderDirectory``
    ///   from the same credentials, so rules show folder names rather than
    ///   opaque ids. Needs `Mail.ReadBasic`, which ``GraphScopes/default``
    ///   requests. Pass `false` for a store built on a narrower token.
    public init(
        tokenProvider: any TokenProvider,
        baseURL: URL = GraphMessageRuleClient.defaultBaseURL,
        session: URLSession = .shared,
        resolveFolderNames: Bool = true
    ) {
        self.client = GraphMessageRuleClient(
            tokenProvider: tokenProvider, baseURL: baseURL, session: session
        )
        self.directory = resolveFolderNames
            ? GraphMailFolderDirectory(tokenProvider: tokenProvider, baseURL: baseURL, session: session)
            : nil
    }

    public func listRules() async throws -> [MailRule] {
        let natives = try await client.listRules()
        // One folder fetch for the whole list. If it fails (no Mail.ReadBasic,
        // a blip), rules still load and show raw ids, and the directory is
        // not asked again for every action.
        let canResolve = await folderDirectoryIsAvailable()
        var resolved: [MailRule] = []
        for native in natives {
            let rule = try mapper.decode(native)
            resolved.append(canResolve ? await namingFolders(in: rule) : rule)
        }
        return resolved
    }

    public func rule(id: String) async throws -> MailRule {
        await namingFolders(in: try mapper.decode(try await client.rule(id: id)))
    }

    public func createRule(_ rule: MailRule) async throws -> MailRule {
        var native = try mapper.encode(try await addressingFolders(in: rule))
        // Graph requires a sequence on create, and clamps one past the end to
        // N+1, so this appends without knowing N.
        if native.sequence == nil { native.sequence = GraphRuleMapper.appendSequence }
        return await namingFolders(in: try mapper.decode(try await client.createRule(native)))
    }

    public func updateRule(id: String, with rule: MailRule) async throws -> MailRule {
        let native = try mapper.encode(try await addressingFolders(in: rule))
        return await namingFolders(in: try mapper.decode(try await client.updateRule(id: id, with: native)))
    }

    public func moveRule(id: String, toPosition position: Int) async throws {
        _ = try await client.moveRule(id: id, toSequence: max(1, position))
    }

    public func deleteRule(id: String) async throws {
        try await client.deleteRule(id: id)
    }

    // MARK: - Folder resolution

    private func folderDirectoryIsAvailable() async -> Bool {
        guard let directory else { return false }
        return (try? await directory.folders()) != nil
    }

    /// Reading: opaque ids gain readable names. Best-effort, since a rule with
    /// a raw id is still a rule worth showing.
    private func namingFolders(in rule: MailRule) async -> MailRule {
        guard let directory else { return rule }
        return await rule.mappingFolders { await directory.resolve($0) }
    }

    /// Writing: a folder chosen by name needs its id, and Graph refuses a
    /// display name ("Id is malformed."). A failed lookup is thrown, not
    /// swallowed, so the person sees why rather than a bad request.
    private func addressingFolders(in rule: MailRule) async throws -> MailRule {
        guard let directory else { return rule }
        var updated = rule
        updated.actions = []
        for action in rule.actions {
            switch action {
            case .moveTo(let folder): updated.actions.append(.moveTo(try await directory.addressing(folder)))
            case .copyTo(let folder): updated.actions.append(.copyTo(try await directory.addressing(folder)))
            default: updated.actions.append(action)
            }
        }
        return updated
    }
}

private extension FolderDirectory {
    func addressing(_ folder: MailboxFolder) async throws -> MailboxFolder {
        guard folder.id == nil, let name = folder.name, !name.isEmpty else { return folder }
        var resolved = folder
        resolved.id = try await id(forName: name)
        return resolved
    }
}

private extension MailRule {
    func mappingFolders(_ transform: (MailboxFolder) async -> MailboxFolder) async -> MailRule {
        var updated = self
        updated.actions = []
        for action in actions {
            switch action {
            case .moveTo(let folder): updated.actions.append(.moveTo(await transform(folder)))
            case .copyTo(let folder): updated.actions.append(.copyTo(await transform(folder)))
            // Categories are not folders; looking one up by name could pick
            // up a folder that happens to share it.
            default: updated.actions.append(action)
            }
        }
        return updated
    }
}
