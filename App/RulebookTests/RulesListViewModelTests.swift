import Foundation
import Testing
import RulebookKit
import RulebookTesting
@testable import Rulebook

/// The rules list, driven the way the screen drives it, against FakeGraph:
/// the real GraphRuleStore and mapper, talking to a fake that behaves the way
/// recorded Graph does.
@MainActor
@Suite("Rules list")
struct RulesListViewModelTests {

    /// A list over a mailbox holding `names`, in that order, all enabled.
    func makeList(_ names: [String], disabled: Set<String> = [], fake: FakeGraph = FakeGraph()) async throws -> (RulesListViewModel, FakeGraph) {
        let store = fake.makeStore()
        for name in names {
            _ = try await store.createRule(MailRule(
                name: name, isEnabled: !disabled.contains(name),
                conditions: [.subject(StringMatch(name))], actions: [.markAsRead(true)]
            ))
        }
        let model = RulesListViewModel(store: store, folders: fake.makeFolderDirectory())
        await model.load()
        fake.clearRequestLog()
        return (model, fake)
    }

    // MARK: Reorder

    @Test("Dragging a rule to the top is one request, and Outlook's order follows")
    func dragToTop() async throws {
        let (model, fake) = try await makeList(["A", "B", "C", "D"])

        await model.move(from: IndexSet(integer: 3), to: 0)

        #expect(fake.writes.count == 1)
        #expect(fake.writes.first?.json?["sequence"] as? Int == 1)
        #expect(fake.storedRules.map { $0["displayName"] as! String } == ["D", "A", "B", "C"])
        #expect(model.rules.map(\.name) == ["D", "A", "B", "C"])
        #expect(model.errorMessage == nil)
    }

    @Test("Dragging down works too")
    func dragDown() async throws {
        let (model, fake) = try await makeList(["A", "B", "C", "D"])
        // SwiftUI's offset: A dropped before the row at index 3 (D).
        await model.move(from: IndexSet(integer: 0), to: 3)
        #expect(fake.storedRules.map { $0["displayName"] as! String } == ["B", "C", "A", "D"])
    }

    @Test("With a filter on, the dragged rule is the one that moves")
    func dragWhileFiltered() async throws {
        let (model, fake) = try await makeList(["A", "off-1", "B", "off-2", "C"], disabled: ["off-1", "off-2"])
        model.filter = .enabled
        #expect(model.visibleRules.map(\.name) == ["A", "B", "C"])

        // Drag C (visible row 2) above B (visible row 1).
        await model.move(from: IndexSet(integer: 2), to: 1)

        let order = fake.storedRules.map { $0["displayName"] as! String }
        #expect(order.firstIndex(of: "C")! < order.firstIndex(of: "B")!)
        #expect(order.firstIndex(of: "A")! < order.firstIndex(of: "C")!)
        #expect(order.filter { $0.hasPrefix("off") } == ["off-1", "off-2"])
    }

    @Test("Move this rule up puts it first")
    func hoist() async throws {
        let (model, fake) = try await makeList(["A", "B", "C"])
        let c = try #require(model.rules.last)
        await model.hoist(c)
        #expect(fake.storedRules.first?["displayName"] as? String == "C")
        #expect(fake.writes.count == 1)
    }

    // MARK: Toggling and deleting

    @Test("Turning a rule off doesn't move it")
    func toggleKeepsPosition() async throws {
        let (model, fake) = try await makeList(["A", "B", "C"])
        let c = try #require(model.rules.last)

        await model.setEnabled(false, on: c)

        #expect(fake.writes.first?.json?["sequence"] == nil, "A toggle must not send a position.")
        #expect(fake.storedRules.map { $0["displayName"] as! String } == ["A", "B", "C"])
        #expect(fake.storedRule(named: "C")?["isEnabled"] as? Bool == false)
    }

    @Test("A stale copy can't move a rule: toggling after another rule moved keeps the new order")
    func toggleAfterReorderElsewhere() async throws {
        let (model, fake) = try await makeList(["A", "B", "C"])
        let staleA = try #require(model.rules.first)
        // Someone moves C to the top in Outlook; A is now 2nd, but our copy says 1.
        try await fake.makeStore().moveRule(id: model.rules.last!.id!, toPosition: 1)

        await model.setEnabled(false, on: staleA)

        #expect(fake.storedRules.map { $0["displayName"] as! String } == ["C", "A", "B"])
    }

    @Test("Deleting a rule that's already gone counts as deleted")
    func deleteAlreadyGone() async throws {
        let (model, fake) = try await makeList(["A", "B"])
        let a = try #require(model.rules.first)
        try await fake.makeStore().deleteRule(id: a.id!)

        await model.delete(a)

        #expect(model.errorMessage == nil)
        #expect(!model.rules.contains { $0.id == a.id })
    }

    @Test("A failed delete puts the rule back and says it's still running")
    func failedDeleteRestores() async throws {
        let (model, fake) = try await makeList(["A", "B"])
        fake.inject(.init(method: "DELETE", status: 500, code: "InternalServerError"))
        let a = try #require(model.rules.first)

        await model.delete(a)

        #expect(model.rules.contains { $0.id == a.id })
        #expect(model.errorMessage?.contains("still running") == true)
    }

    // MARK: Pending changes

    @Test("A toggle that can't reach Outlook is kept, and a retry delivers it")
    func pendingThenRetry() async throws {
        let (model, fake) = try await makeList(["A"])
        fake.inject(.init(method: "PATCH", status: 503, headers: ["Retry-After": "0"], times: 3))
        let a = try #require(model.rules.first)

        await model.setEnabled(false, on: a)
        #expect(model.hasPending)
        #expect(model.rules.first?.isEnabled == false, "The change stays on screen.")

        await model.load()
        #expect(model.rules.first?.isEnabled == false, "A refresh doesn't undo it.")

        await model.retryPending()
        #expect(!model.hasPending)
        #expect(fake.storedRule(named: "A")?["isEnabled"] as? Bool == false)
    }

    @Test("Saving the rule in the editor supersedes an older unsent toggle")
    func editorSaveClearsPending() async throws {
        let (model, fake) = try await makeList(["A"])
        fake.inject(.init(method: "PATCH", status: 503, headers: ["Retry-After": "0"], times: 3))
        let a = try #require(model.rules.first)
        await model.setEnabled(false, on: a)
        #expect(model.hasPending)

        var edited = try #require(try await fake.makeStore().rule(id: a.id!))
        edited.name = "A edited"
        model.noteSaved(edited)

        #expect(!model.hasPending)
    }

    @Test("A pending change for a rule deleted elsewhere is dropped, not retried forever")
    func pendingForDeletedRule() async throws {
        let (model, fake) = try await makeList(["A", "B"])
        fake.inject(.init(method: "PATCH", status: 503, headers: ["Retry-After": "0"], times: 3))
        let a = try #require(model.rules.first)
        await model.setEnabled(false, on: a)
        try await fake.makeStore().deleteRule(id: a.id!)

        await model.retryPending()

        #expect(!model.hasPending)
    }

    // MARK: Loading

    @Test("When two loads overlap, the newer one wins")
    func overlappingLoads() async throws {
        let store = ScriptedStore()
        let model = RulesListViewModel(store: store, folders: StaticFolderDirectory([:]))
        store.responses = [
            (delay: .milliseconds(200), rules: [MailRule(id: "1", name: "Old", order: 1, actions: [.markAsRead(true)])]),
            (delay: .zero, rules: [MailRule(id: "1", name: "New", order: 1, actions: [.markAsRead(true)])]),
        ]
        async let first: Void = model.load()
        try await Task.sleep(for: .milliseconds(20))
        async let second: Void = model.load()
        _ = await (first, second)

        #expect(model.rules.map(\.name) == ["New"])
        #expect(!model.isLoading)
    }

    @Test("If the folder list can't load, rules that file mail are not reported as broken")
    func noFalseMissingFolder() async throws {
        let fake = FakeGraph()
        let store = fake.makeStore()
        _ = try await store.createRule(MailRule(name: "Filed", conditions: [.subject(StringMatch("x"))],
                                                actions: [.moveTo(.named("Receipts"))]))
        fake.inject(.init(target: .folders, status: 503, headers: ["Retry-After": "0"], times: 100))
        let model = RulesListViewModel(store: fake.makeStore(), folders: fake.makeFolderDirectory())

        await model.load()

        #expect(model.rules.count == 1)
        #expect(model.issues.isEmpty)
    }

    @Test("A rule with no conditions that deletes is flagged as running on every message")
    func everyMessageIsFlagged() async throws {
        let fake = FakeGraph(rules: [[
            "id": "r1", "displayName": "Was: delete if no attachment", "sequence": 1, "isEnabled": true,
            "actions": ["delete": true, "stopProcessingRules": true],
        ]])
        let model = RulesListViewModel(store: fake.makeStore(), folders: fake.makeFolderDirectory())
        await model.load()
        let issue = try #require(model.issues.first)
        #expect(issue.kind == .appliesToEverything(destructive: true))
        #expect(issue.level == .error)
    }

    @Test("Turning off a catch-all stop clears the never-runs warnings without a reload")
    func issuesFollowToggles() async throws {
        let fake = FakeGraph(rules: [
            ["id": "stop", "displayName": "Stop", "sequence": 1, "isEnabled": true, "actions": ["stopProcessingRules": true]],
            ["id": "later", "displayName": "Later", "sequence": 2, "isEnabled": true,
             "conditions": ["subjectContains": ["x"]], "actions": ["markAsRead": true]],
        ])
        let model = RulesListViewModel(store: fake.makeStore(), folders: fake.makeFolderDirectory())
        await model.load()
        #expect(model.issues.contains { $0.ruleID == "later" })

        await model.setEnabled(false, on: try #require(model.rules.first))

        #expect(!model.issues.contains { $0.ruleID == "later" })
    }

    // MARK: Pro

    @Test("On the free tier every write raises the paywall and sends nothing")
    func freeTierWritesNothing() async throws {
        let (model, fake) = try await makeList(["A", "B"])
        model.pro = ProStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let a = try #require(model.rules.first)

        await model.setEnabled(false, on: a)
        #expect(model.paywall == .toggle)
        await model.delete(a)
        #expect(model.paywall == .delete)
        await model.move(from: IndexSet(integer: 1), to: 0)
        #expect(model.paywall == .reorder)
        _ = await model.duplicate(a)
        #expect(model.paywall == .duplicate)

        #expect(fake.writes.isEmpty)
        #expect(model.isLocked)
    }

    @Test("Read-only rules are skipped by bulk changes and can't be dragged")
    func readOnlyRules() async throws {
        let (model, fake) = try await makeList(["A", "B"])
        let a = try #require(model.rules.first)
        fake.setReadOnly(a.id!)
        await model.load()
        fake.clearRequestLog()

        model.selection = Set(model.rules.compactMap(\.id))
        await model.applyToSelection(enabled: false)
        #expect(fake.writes.count == 1)

        await model.move(from: IndexSet(integer: 0), to: 2)
        #expect(fake.writes.count == 1, "Dragging a read-only rule sends nothing.")
    }
}

/// A store whose listRules answers are scripted, delays included.
final class ScriptedStore: RuleStore, @unchecked Sendable {
    let capabilities = GraphRuleMapper.capabilities
    private let lock = NSLock()
    private var queue: [(delay: Duration, rules: [MailRule])] = []

    var responses: [(delay: Duration, rules: [MailRule])] {
        get { lock.withLock { queue } }
        set { lock.withLock { queue = newValue } }
    }

    func listRules() async throws -> [MailRule] {
        let next = lock.withLock { queue.isEmpty ? (delay: Duration.zero, rules: [MailRule]()) : queue.removeFirst() }
        try await Task.sleep(for: next.delay)
        return next.rules
    }
    func rule(id: String) async throws -> MailRule { throw RuleStoreError.notFound(id: id) }
    func createRule(_ rule: MailRule) async throws -> MailRule { rule }
    func updateRule(id: String, with rule: MailRule) async throws -> MailRule { rule }
    func moveRule(id: String, toPosition position: Int) async throws {}
    func deleteRule(id: String) async throws {}
}
