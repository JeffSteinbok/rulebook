import Foundation
import Testing
@testable import RulebookKit
import RulebookTesting

/// Tests that talk to a real Microsoft 365 mailbox.
///
/// Skipped unless `RULEBOOK_LIVE=1`, so `swift test` never touches an account
/// by accident. Writes need a second opt-in, `RULEBOOK_LIVE_WRITE=1`, and even
/// then they create and delete one scratch rule.
///
///     RULEBOOK_LIVE=1 swift test --filter LiveOutlook              # read-only
///     RULEBOOK_LIVE=1 RULEBOOK_LIVE_WRITE=1 swift test --filter LiveOutlook
///
/// Credentials come from `RULEBOOK_ACCESS_TOKEN` if set, otherwise from the
/// token `rulebook login` cached. These verify what a stubbed URLProtocol
/// structurally cannot: that Graph accepts the payloads the mapper produces,
/// and that real rules survive the round trip through the neutral model.
enum Live {
    static let isEnabled = ProcessInfo.processInfo.environment["RULEBOOK_LIVE"] == "1"
    static let isWriteEnabled = isEnabled
        && ProcessInfo.processInfo.environment["RULEBOOK_LIVE_WRITE"] == "1"

    static func store() throws -> GraphRuleStore {
        let environment = ProcessInfo.processInfo.environment

        if let token = environment["RULEBOOK_ACCESS_TOKEN"], !token.isEmpty {
            return GraphRuleStore(tokenProvider: StaticTokenProvider(token))
        }

        guard let clientID = environment["RULEBOOK_CLIENT_ID"], !clientID.isEmpty else {
            throw LiveTestError.noCredentials
        }
        return GraphRuleStore(tokenProvider: DeviceCodeTokenProvider(
            configuration: .init(
                clientID: clientID,
                tenantID: environment["RULEBOOK_TENANT_ID"] ?? "common"
            ),
            // A live test must never block waiting for someone to type a code.
            prompt: { _ in }
        ))
    }

    /// Drops resolved display names so two actions compare on folder id alone.
    static func byFolderID(_ action: RuleAction) -> RuleAction {
        func bare(_ folder: MailboxFolder) -> MailboxFolder {
            folder.id.map(MailboxFolder.id) ?? folder
        }
        switch action {
        case .moveTo(let f): return .moveTo(bare(f))
        case .copyTo(let f): return .copyTo(bare(f))
        case .addLabel(let f): return .addLabel(bare(f))
        case .removeLabel(let f): return .removeLabel(bare(f))
        default: return action
        }
    }

    enum LiveTestError: Error, CustomStringConvertible {
        case noCredentials
        var description: String {
            "Set RULEBOOK_ACCESS_TOKEN, or RULEBOOK_CLIENT_ID after `rulebook login`."
        }
    }
}

@Suite("Live Outlook — read", .serialized, .enabled(if: Live.isEnabled))
struct LiveOutlookReadTests {

    @Test("The mailbox's rules list")
    func listsRules() async throws {
        let rules = try await Live.store().listRules()
        print("Mailbox has \(rules.count) rule(s).")
        for rule in rules {
            print(ProviderCatalog.outlook.describe(rule))
        }
    }

    @Test("Every real rule survives the neutral round trip")
    func realRulesRoundTrip() async throws {
        let mapper = GraphRuleMapper()
        let rules = try await Live.store().listRules()

        try #require(!rules.isEmpty, "No rules in the mailbox — create one in Outlook to exercise this.")

        for rule in rules {
            // Skip what Outlook itself flags as broken or frozen.
            guard rule.status.isClean else { continue }

            let reencoded = try mapper.encode(rule)
            let back = try mapper.decode(reencoded)

            #expect(back.name == rule.name)
            #expect(back.order == rule.order)
            #expect(Set(back.conditions) == Set(rule.conditions), "conditions drifted for \"\(rule.name)\"")
            // Compare on folder *identity*. The store enriches folders with
            // display names from the directory; the mapper only round-trips the
            // id, so comparing names would be testing the wrong layer.
            #expect(
                Set(back.actions.map(Live.byFolderID)) == Set(rule.actions.map(Live.byFolderID)),
                "actions drifted for \"\(rule.name)\""
            )
        }
    }

    @Test("Every real rule passes validation")
    func realRulesValidate() async throws {
        let rules = try await Live.store().listRules()
        let issues = rules
            .filter(\.status.isClean)
            .flatMap { RuleValidator.validate($0, for: GraphRuleMapper.capabilities) }

        for issue in issues { print(issue.description) }
        #expect(!issues.hasErrors, "Rules Outlook accepted should not fail our own checks.")
    }
}

@Suite("Live Outlook — write", .serialized, .enabled(if: Live.isWriteEnabled))
struct LiveOutlookWriteTests {

    @Test("A scratch rule survives create, read back, and delete")
    func createReadDelete() async throws {
        let store = try Live.store()
        let name = "RuleBook scratch — safe to delete \(UUID().uuidString.prefix(8))"

        let rule = MailRule(
            name: name,
            // High order so it sits after anything real in the mailbox.
            order: 900,
            isEnabled: false,
            conditions: [
                .from(StringMatch(["rulebook-live-test@example.invalid"], mode: .equals)),
                .subject(StringMatch(["RuleBook live test"])),
                .hasAttachment(true),
            ],
            actions: [.markAsRead(true), .addLabel(.named("RuleBookTest")), .stopProcessing]
        )

        let created = try await store.createRule(rule)
        let id = try #require(created.id, "Graph returned no id for the created rule.")

        // Delete it whatever the assertions below do.
        defer {
            Task { try? await store.deleteRule(id: id) }
        }

        // Graph is the authority: read it back rather than trusting the POST response.
        let fetched = try await store.rule(id: id)
        #expect(fetched.name == name)
        // Graph keeps sequences dense, so 900 lands at the end of the list.
        // Other live suites run alongside, so "the end" isn't a fixed number.
        #expect((fetched.order ?? 0) >= 1 && (fetched.order ?? 0) < 900)
        #expect(fetched.isEnabled == false)
        #expect(Set(fetched.conditions) == Set(rule.conditions), "Graph did not preserve the conditions")
        #expect(Set(fetched.actions) == Set(rule.actions), "Graph did not preserve the actions")

        try await store.deleteRule(id: id)

        do {
            _ = try await store.rule(id: id)
            Issue.record("The rule still exists after delete.")
        } catch let RuleStoreError.notFound(missing) {
            #expect(missing == id)
        }
    }
}


/// What `OutlookFidelityTests` checks against FakeGraph, checked against real
/// Outlook: every condition and action the app can build is stored as meant.
/// Each scratch rule is disabled, named "RuleBook live – …", and deleted
/// whatever the assertions do.
@Suite("Live Outlook — fidelity", .serialized, .enabled(if: Live.isWriteEnabled))
struct LiveOutlookFidelityTests {

    static let prefix = "RuleBook live – "

    /// Creates `rule`, hands back what Graph stored, and always deletes it.
    func scratch(_ rule: MailRule, _ check: (MailRule, GraphRuleStore) async throws -> Void) async throws {
        let store = try Live.store()
        var rule = rule
        rule.name = Self.prefix + rule.name
        rule.isEnabled = false
        let created = try await store.createRule(rule)
        let id = try #require(created.id)
        do {
            try await check(try await store.rule(id: id), store)
        } catch {
            try? await store.deleteRule(id: id)
            throw error
        }
        try await store.deleteRule(id: id)
    }

    @Test("Each condition reads back as meant", arguments: RuleSamples.conditions)
    func condition(_ condition: RuleCondition) async throws {
        try await scratch(MailRule(name: condition.description, conditions: [condition], actions: [.markAsRead(true)])) { stored, _ in
            #expect(stored.conditions == [condition])
        }
    }

    @Test("Each condition reads back as meant, as an exception", arguments: RuleSamples.conditions)
    func exception(_ condition: RuleCondition) async throws {
        try await scratch(MailRule(
            name: "unless " + condition.description,
            conditions: [.from(StringMatch(["rulebook-live@example.invalid"]))],
            exceptions: [condition], actions: [.markAsRead(true)]
        )) { stored, _ in
            #expect(stored.exceptions == [condition])
        }
    }

    static let actions: [[RuleAction]] = RuleSamples.folderlessActions + [
        [.moveTo(.named("Archive"))],
        [.copyTo(.named("Junk Email"))],
        [.moveTo(.named("Archive")), .stopProcessing],
    ]

    @Test("Each action reads back as meant", arguments: actions)
    func action(_ actions: [RuleAction]) async throws {
        try await scratch(MailRule(
            name: actions.map(\.description).joined(separator: ", "),
            conditions: [.from(StringMatch(["rulebook-live@example.invalid"]))], actions: actions
        )) { stored, _ in
            #expect(stored.actions.map(Live.byFolderName) == actions.map(Live.byFolderName))
        }
    }

    @Test("Removing every exception clears them")
    func clearingExceptions() async throws {
        try await scratch(MailRule(
            name: "clear exceptions", conditions: [.from(StringMatch(["rulebook-live@example.invalid"]))],
            exceptions: [.subject(StringMatch("keep"))], actions: [.markAsRead(true)]
        )) { stored, store in
            var edited = stored
            edited.exceptions = []
            edited.order = nil
            _ = try await store.updateRule(id: stored.id!, with: edited)
            #expect(try await store.rule(id: stored.id!).exceptions.isEmpty)
        }
    }

    @Test("Moving a rule up is one request and the rest shift down")
    func reorder() async throws {
        let store = try Live.store()
        let condition = RuleCondition.from(StringMatch(["rulebook-live@example.invalid"]))
        let a = try await store.createRule(MailRule(name: Self.prefix + "reorder A", isEnabled: false, conditions: [condition], actions: [.markAsRead(true)]))
        let b = try await store.createRule(MailRule(name: Self.prefix + "reorder B", isEnabled: false, conditions: [condition], actions: [.markAsRead(true)]))
        defer { Task { try? await store.deleteRule(id: a.id!); try? await store.deleteRule(id: b.id!) } }

        let before = try await store.listRules()
        let positionOfA = try #require(before.firstIndex { $0.id == a.id }) + 1
        try await store.moveRule(id: b.id!, toPosition: positionOfA)

        let after = try await store.listRules()
        let ia = try #require(after.firstIndex { $0.id == a.id })
        let ib = try #require(after.firstIndex { $0.id == b.id })
        #expect(ib == ia - 1, "B should now sit directly above A.")
        #expect(after.map(\.order) == Array(1...after.count).map(Optional.some), "Outlook keeps positions 1…N.")
        let others = { (rules: [MailRule]) in rules.filter { !$0.name.hasPrefix(Self.prefix) }.map(\.id) }
        #expect(others(after) == others(before), "Rules we didn't move keep their relative order.")

        try await store.deleteRule(id: a.id!)
        try await store.deleteRule(id: b.id!)
    }
}

extension Live {
    /// Folders compare by their leaf name; the store resolves ids to paths.
    static func byFolderName(_ action: RuleAction) -> RuleAction {
        func leaf(_ folder: MailboxFolder) -> MailboxFolder {
            .named(String((folder.name ?? folder.id ?? "").split(separator: "/").last ?? ""))
        }
        switch action {
        case .moveTo(let f): return .moveTo(leaf(f))
        case .copyTo(let f): return .copyTo(leaf(f))
        default: return action
        }
    }
}
