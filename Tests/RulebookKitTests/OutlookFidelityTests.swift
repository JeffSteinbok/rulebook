import Foundation
import Testing
@testable import RulebookKit
import RulebookTesting

/// What someone builds in the app is what Outlook stores.
///
/// Each case goes through the real ``GraphRuleStore`` and mapper into
/// ``FakeGraph``, whose behaviour is pinned to recordings of real Graph by
/// `GraphConformanceTests`. Then it reads the rule back the way the app does.
/// A rule that survives this means the same thing in Outlook as it did on
/// screen. One Outlook can't express is refused before anything is sent.
@Suite("Outlook stores what was meant")
struct OutlookFidelityTests {

    // MARK: Every condition and action

    static let conditions = RuleSamples.conditions

    @Test("Each condition reads back exactly", arguments: conditions)
    func conditionSurvives(_ condition: RuleCondition) async throws {
        let fake = FakeGraph()
        let created = try await fake.makeStore().createRule(MailRule(
            name: "Condition", conditions: [condition], actions: [.markAsRead(true)]
        ))
        let stored = try await fake.makeStore().rule(id: try #require(created.id))
        #expect(stored.conditions == [condition])
    }

    @Test("Each condition reads back exactly as an exception", arguments: conditions)
    func exceptionSurvives(_ condition: RuleCondition) async throws {
        let fake = FakeGraph()
        let created = try await fake.makeStore().createRule(MailRule(
            name: "Exception", conditions: [.subject(StringMatch("x"))],
            exceptions: [condition], actions: [.markAsRead(true)]
        ))
        let stored = try await fake.makeStore().rule(id: try #require(created.id))
        #expect(stored.exceptions == [condition])
    }

    static let actions: [[RuleAction]] = RuleSamples.folderlessActions + [
        [.moveTo(.named("Receipts"))],
        [.moveTo(.named("Newsletters/Tech"))],
        [.copyTo(.named("Archive"))],
        [.moveTo(.named("Receipts")), .stopProcessing],
    ]

    @Test("Each action reads back exactly", arguments: actions)
    func actionSurvives(_ actions: [RuleAction]) async throws {
        let fake = FakeGraph()
        let store = fake.makeStore()
        let created = try await store.createRule(MailRule(
            name: "Action", conditions: [.subject(StringMatch("x"))], actions: actions
        ))
        let stored = try await store.rule(id: try #require(created.id))
        #expect(stored.actions.map(Self.byName) == actions.map(Self.byName))
    }

    @Test("A delete always comes back with stop-processing, because Outlook adds it")
    func deleteGainsStop() async throws {
        let fake = FakeGraph()
        let store = fake.makeStore()
        let created = try await store.createRule(MailRule(
            name: "Delete", conditions: [.subject(StringMatch("x"))], actions: [.delete(permanent: false)]
        ))
        let stored = try await store.rule(id: try #require(created.id))
        #expect(stored.actions == [.delete(permanent: false), .stopProcessing])
    }

    @Test("A move to Deleted Items comes back as a delete")
    func moveToDeletedItemsIsADelete() async throws {
        let fake = FakeGraph()
        let store = fake.makeStore()
        let created = try await store.createRule(MailRule(
            name: "Trash it", conditions: [.subject(StringMatch("x"))], actions: [.moveTo(.named("Deleted Items"))]
        ))
        let stored = try await store.rule(id: try #require(created.id))
        #expect(stored.actions == [.delete(permanent: false)])
    }

    // MARK: Refused before anything is sent

    @Test("Negated tests are refused, with the exception that means the same thing", arguments: RuleSamples.negated)
    func negatedTestsAreRefused(_ negated: RuleCondition) async throws {
        let fake = FakeGraph()
        let rule = MailRule(name: "Negated", conditions: [negated], actions: [.delete(permanent: false)])

        // The capability check catches it first, which is what the editor shows.
        let early = RuleValidator.validate(rule, for: GraphRuleMapper.capabilities)
        #expect(early.hasErrors)
        #expect(early.contains { $0.remedy?.contains("exception") == true })

        do {
            _ = try await fake.makeStore().createRule(rule)
            Issue.record("A negated test must not reach Outlook: it would match every message.")
        } catch let MappingError.unsupported(issues) {
            #expect(issues.contains { $0.message.contains("every message") })
        }
        #expect(fake.writes.isEmpty)
    }

    @Test("Two conditions on the same field are refused rather than one silently replacing the other")
    func duplicateFieldIsRefused() async throws {
        let fake = FakeGraph()
        let rule = MailRule(name: "Twice", conditions: [
            .subject(StringMatch("a")), .subject(StringMatch("b")),
        ], actions: [.markAsRead(true)])
        await #expect(throws: MappingError.self) { try await fake.makeStore().createRule(rule) }
        #expect(fake.writes.isEmpty)
    }

    @Test("A move with no folder chosen is refused", arguments: [
        MailboxFolder.named(""), MailboxFolder(),
    ])
    func folderlessMoveIsRefused(_ folder: MailboxFolder) async throws {
        let fake = FakeGraph()
        let rule = MailRule(name: "Nowhere", conditions: [.subject(StringMatch("x"))], actions: [.moveTo(folder)])
        await #expect(throws: (any Error).self) { try await fake.makeStore().createRule(rule) }
        #expect(fake.writes.isEmpty)
        #expect(RuleValidator.validate(rule).hasErrors)
    }

    @Test("A folder that isn't in the mailbox is refused, not sent as a name")
    func unknownFolderIsRefused() async throws {
        let fake = FakeGraph()
        let rule = MailRule(name: "Gone", conditions: [.subject(StringMatch("x"))], actions: [.moveTo(.named("Nope"))])
        await #expect(throws: MappingError.self) { try await fake.makeStore().createRule(rule) }
        #expect(fake.writes.isEmpty)
    }

    @Test("When the folder list can't be fetched, a write says so instead of sending a bad request")
    func folderLookupFailureSurfaces() async throws {
        let fake = FakeGraph()
        fake.inject(.init(target: .folders, status: 403, code: "ErrorAccessDenied",
                          message: "Access is denied.", times: 10))
        let rule = MailRule(name: "Filed", conditions: [.subject(StringMatch("x"))], actions: [.moveTo(.named("Receipts"))])
        do {
            _ = try await fake.makeStore().createRule(rule)
            Issue.record("Expected the folder lookup failure.")
        } catch let RuleStoreError.provider(_, status, _, _) {
            #expect(status == 403)
        }
        #expect(fake.writes.isEmpty)
    }

    // MARK: Editing

    @Test("Removing every exception clears them in Outlook")
    func clearingExceptions() async throws {
        let fake = FakeGraph()
        let store = fake.makeStore()
        var rule = try await store.createRule(MailRule(
            name: "With exceptions", conditions: [.subject(StringMatch("x"))],
            exceptions: [.body(StringMatch("keep"))], actions: [.markAsRead(true)]
        ))
        rule.exceptions = []
        _ = try await store.updateRule(id: rule.id!, with: rule)

        #expect(fake.storedRule(named: "With exceptions")?["exceptions"] == nil)
        #expect(try await store.rule(id: rule.id!).exceptions.isEmpty)
    }

    @Test("Removing every condition clears them in Outlook")
    func clearingConditions() async throws {
        let fake = FakeGraph()
        let store = fake.makeStore()
        var rule = try await store.createRule(MailRule(
            name: "With conditions", conditions: [.subject(StringMatch("x"))], actions: [.markAsRead(true)]
        ))
        rule.conditions = []
        _ = try await store.updateRule(id: rule.id!, with: rule)
        #expect(try await store.rule(id: rule.id!).conditions.isEmpty)
    }

    @Test("Changing one condition replaces the set, as Graph does")
    func editingConditionsReplaces() async throws {
        let fake = FakeGraph()
        let store = fake.makeStore()
        var rule = try await store.createRule(MailRule(
            name: "Edited", conditions: [.subject(StringMatch("one")), .hasAttachment(true)],
            actions: [.markAsRead(true)]
        ))
        rule.conditions = [.body(StringMatch("two"))]
        _ = try await store.updateRule(id: rule.id!, with: rule)
        #expect(try await store.rule(id: rule.id!).conditions == [.body(StringMatch("two"))])
    }

    @Test("Saving an edit keeps the rule where it was")
    func editKeepsPosition() async throws {
        let fake = FakeGraph()
        let store = fake.makeStore()
        for name in ["A", "B", "C"] {
            _ = try await store.createRule(MailRule(name: name, conditions: [.subject(StringMatch(name))], actions: [.markAsRead(true)]))
        }
        var c = try #require(try await store.listRules().last)
        c.name = "C renamed"
        c.order = nil
        _ = try await store.updateRule(id: c.id!, with: c)
        #expect(try await store.listRules().map(\.name) == ["A", "B", "C renamed"])
    }

    @Test("A new rule goes after the existing ones")
    func createAppends() async throws {
        let fake = FakeGraph()
        let store = fake.makeStore()
        for name in ["First", "Second"] {
            _ = try await store.createRule(MailRule(name: name, conditions: [.subject(StringMatch(name))], actions: [.markAsRead(true)]))
        }
        #expect(try await store.listRules().map(\.name) == ["First", "Second"])
        #expect(try await store.listRules().map(\.order) == [1, 2])
    }

    @Test("Moving a rule is one request, and the others shift down")
    func moveIsOneRequest() async throws {
        let fake = FakeGraph()
        let store = fake.makeStore()
        for name in ["A", "B", "C", "D"] {
            _ = try await store.createRule(MailRule(name: name, conditions: [.subject(StringMatch(name))], actions: [.markAsRead(true)]))
        }
        let d = try #require(try await store.listRules().last?.id)
        fake.clearRequestLog()

        try await store.moveRule(id: d, toPosition: 1)

        #expect(fake.writes.count == 1)
        #expect(fake.writes.first?.json?.keys.sorted() == ["sequence"])
        #expect(try await store.listRules().map(\.name) == ["D", "A", "B", "C"])
        #expect(try await store.listRules().map(\.order) == [1, 2, 3, 4])
    }

    // MARK: Reading

    @Test("Sender text Outlook upper-cased reads back as typed")
    func casingIsNormalised() async throws {
        let fake = FakeGraph(rules: [[
            "id": "r1", "displayName": "Upper", "sequence": 1, "isEnabled": true,
            "conditions": ["senderContains": ["NEWS@EXAMPLE.COM"]], "actions": ["markAsRead": true],
        ]])
        let rule = try #require(try await fake.makeStore().listRules().first)
        #expect(rule.conditions == [.from(StringMatch(["news@example.com"]))])
    }

    @Test("A rule missing its name or sequence doesn't hide every other rule")
    func tolerantDecoding() async throws {
        let fake = FakeGraph(rules: [
            ["id": "odd", "isEnabled": true, "actions": ["markAsRead": true]],
            ["id": "fine", "displayName": "Fine", "isEnabled": true, "actions": ["markAsRead": true]],
        ])
        let rules = try await fake.makeStore().listRules()
        #expect(rules.count == 2)
    }

    @Test("Rules still load when the folder list can't, and the folders are asked once")
    func folderFailureOnRead() async throws {
        let inbox = FakeGraph.standardFolders.first { $0["displayName"] as? String == "Archive" }!["id"] as! String
        let fake = FakeGraph(rules: (1...5).map { index in
            ["id": "r\(index)", "displayName": "Rule \(index)", "sequence": index, "isEnabled": true,
             "actions": ["moveToFolder": inbox]]
        })
        fake.inject(.init(target: .folders, status: 403, code: "ErrorAccessDenied",
                          message: "Access is denied.", times: 100))

        let rules = try await fake.makeStore().listRules()

        #expect(rules.count == 5)
        #expect(rules.first?.actions == [.moveTo(.id(inbox))])
        let folderRequests = fake.requests.filter { $0.path.hasPrefix("me/mailFolders") && !$0.path.contains("messageRules") }
        #expect(folderRequests.count == 1)
    }

    // MARK: Failures

    @Test("A 401 means sign in again")
    func unauthorisedIsNotAuthenticated() async throws {
        let fake = FakeGraph()
        let store = GraphRuleStore(tokenProvider: StaticTokenProvider("expired"), baseURL: fake.baseURL,
                                   session: fake.session, resolveFolderNames: false)
        await #expect(throws: RuleStoreError.self) { _ = try await store.listRules() }
        do { _ = try await store.listRules() } catch RuleStoreError.notAuthenticated {} catch {
            Issue.record("Expected notAuthenticated, got \(error)")
        }
    }

    @Test("Throttling is retried after Retry-After")
    func throttlingIsRetried() async throws {
        let fake = FakeGraph()
        fake.inject(.init(status: 429, code: "TooManyRequests", message: "Slow down.",
                          headers: ["Retry-After": "0"], times: 2))
        let rules = try await fake.makeStore(resolveFolderNames: false).listRules()
        #expect(rules.isEmpty)
        #expect(fake.requests.count == 3)
    }

    @Test("A persistent outage surfaces after the retries")
    func outageSurfaces() async throws {
        let fake = FakeGraph()
        fake.inject(.init(status: 503, headers: ["Retry-After": "0"], times: 10))
        await #expect(throws: RuleStoreError.self) {
            _ = try await fake.makeStore(resolveFolderNames: false).listRules()
        }
        #expect(fake.requests.count == 3)
    }

    @Test("Deleting a rule that is already gone reports notFound")
    func deleteMissing() async throws {
        let fake = FakeGraph()
        do {
            try await fake.makeStore().deleteRule(id: "AQAAAAAAAAA=")
            Issue.record("Expected notFound.")
        } catch RuleStoreError.notFound {}
    }

    // MARK: Helpers

    /// Folder references compare by name: the store resolves ids to names on
    /// the way back.
    /// The store names folders by full path ("Inbox/Receipts"); compare the
    /// tail, which is what was typed.
    static func byName(_ action: RuleAction) -> RuleAction {
        func tail(_ f: MailboxFolder) -> MailboxFolder {
            let name = f.name ?? f.id ?? ""
            for known in ["Newsletters/Tech", "Receipts", "Archive"] where name.hasSuffix(known) {
                return .named(known)
            }
            return .named(name)
        }
        switch action {
        case .moveTo(let f): return .moveTo(tail(f))
        case .copyTo(let f): return .copyTo(tail(f))
        default: return action
        }
    }
}
