import Foundation
import Testing
import RulebookKit
import RulebookTesting
@testable import Rulebook

/// The editor, end to end: what's built on screen is what Outlook stores.
@MainActor
@Suite("Rule editor")
struct RuleEditorModelTests {

    func editor(for rule: MailRule? = nil, fake: FakeGraph) async -> RuleEditorModel {
        let model = RuleEditorModel(editing: rule, store: fake.makeStore(), folders: fake.makeFolderDirectory(),
                                    nextOrder: 1)
        await model.loadFolders()
        return model
    }

    @Test("A new header condition saves; it used to be refused as a named header")
    func headerConditionSaves() async throws {
        let fake = FakeGraph()
        let model = await editor(fake: fake)
        model.draft.name = "Mailer"
        model.draft.conditions = [RuleCondition.blank(.header).replacing(match: StringMatch("X-Mailer"))]
        model.draft.actions = [.markAsRead(true)]

        let saved = await model.save()

        #expect(saved != nil, "\(model.issues)")
        #expect(fake.storedRule(named: "Mailer")?["conditions"] as? [String: [String]] == ["headerContains": ["X-Mailer"]])
    }

    @Test("Has-no-attachment is stopped before save, with the exception as the fix")
    func negatedConditionBlocked() async throws {
        let fake = FakeGraph()
        let model = await editor(fake: fake)
        model.draft.name = "No attachments"
        model.draft.conditions = [.hasAttachment(false)]
        model.draft.actions = [.delete(permanent: false)]

        model.revalidate()

        #expect(!model.canSave)
        #expect(model.blockingIssues.contains { $0.remedy?.contains("exception") == true })
        #expect(await model.save() == nil)
        #expect(fake.writes.isEmpty)
    }

    @Test("The same intent, written as an exception, saves and means it")
    func negatedAsException() async throws {
        let fake = FakeGraph()
        let model = await editor(fake: fake)
        model.draft.name = "No attachments"
        model.draft.conditions = [.from(StringMatch("newsletter"))]
        model.draft.exceptions = [.hasAttachment(true)]
        model.draft.actions = [.markAsRead(true)]

        #expect(await model.save() != nil)
        #expect(fake.storedRule(named: "No attachments")?["exceptions"] as? [String: Bool] == ["hasAttachments": true])
    }

    @Test("A preset that moves mail can't be saved until a folder is chosen")
    func presetNeedsFolder() async throws {
        let fake = FakeGraph()
        let model = RuleEditorModel(store: fake.makeStore(), folders: FailingDirectory())
        RulePreset.all[2].apply(to: model)   // "Invoices to a finance folder"
        model.step = .actions
        model.revalidate()

        #expect(!model.canSave)
        #expect(await model.save() == nil)
        #expect(fake.writes.isEmpty)
    }

    @Test("Choosing the folder makes the preset save, to that folder")
    func presetWithFolder() async throws {
        let fake = FakeGraph()
        let model = await editor(fake: fake)
        RulePreset.all[2].apply(to: model)
        let receipts = try #require(model.availableFolders.first { $0.name == "Inbox/Receipts" })
        model.replaceAction(kind: .moveTo, with: .moveTo(receipts))

        #expect(await model.save() != nil)
        let actions = fake.storedRule(named: "Invoices to a finance folder")?["actions"] as? [String: Any]
        #expect(actions?["moveToFolder"] as? String == "fake-receipts")
    }

    @Test("Removing every exception from a rule clears them in Outlook")
    func clearExceptions() async throws {
        let fake = FakeGraph()
        let store = fake.makeStore()
        let rule = try await store.createRule(MailRule(
            name: "Has exceptions", conditions: [.subject(StringMatch("x"))],
            exceptions: [.body(StringMatch("keep"))], actions: [.markAsRead(true)]
        ))
        let model = await editor(for: rule, fake: fake)
        model.removeException(at: 0)

        #expect(await model.save() != nil)
        #expect(fake.storedRule(named: "Has exceptions")?["exceptions"] == nil)
    }

    @Test("Saving an edit keeps the rule where it is, even if the list moved since")
    func editKeepsCurrentPosition() async throws {
        let fake = FakeGraph()
        let store = fake.makeStore()
        var created: [MailRule] = []
        for name in ["A", "B", "C"] {
            created.append(try await store.createRule(MailRule(name: name, conditions: [.subject(StringMatch(name))], actions: [.markAsRead(true)])))
        }
        // The editor opens on A (position 1)...
        let model = await editor(for: try await store.rule(id: created[0].id!), fake: fake)
        // ...then C is moved to the top elsewhere.
        try await store.moveRule(id: created[2].id!, toPosition: 1)

        model.draft.name = "A edited"
        #expect(await model.save() != nil)

        #expect(fake.storedRules.map { $0["displayName"] as! String } == ["C", "A edited", "B"])
    }

    @Test("A new rule goes after the existing ones")
    func newRuleAppends() async throws {
        let fake = FakeGraph()
        let store = fake.makeStore()
        _ = try await store.createRule(MailRule(name: "Existing", conditions: [.subject(StringMatch("x"))], actions: [.markAsRead(true)]))
        let list = RulesListViewModel(store: store, folders: fake.makeFolderDirectory())
        await list.load()
        let model = list.makeEditor()
        model.draft.name = "New"
        model.draft.conditions = [.subject(StringMatch("y"))]
        model.draft.actions = [.markAsRead(true)]

        #expect(await model.save() != nil)
        #expect(fake.storedRules.map { $0["displayName"] as! String } == ["Existing", "New"])
    }

    @Test("Unsaved changes are noticed, and an untouched rule isn't")
    func unsavedChanges() async throws {
        let fake = FakeGraph()
        let rule = try await fake.makeStore().createRule(MailRule(
            name: "Rule", conditions: [.subject(StringMatch("x"))], actions: [.markAsRead(true)]
        ))
        let model = await editor(for: rule, fake: fake)
        #expect(!model.hasUnsavedChanges)
        model.draft.name = "Renamed"
        #expect(model.hasUnsavedChanges)

        let fresh = await editor(fake: fake)
        #expect(!fresh.hasUnsavedChanges)
        fresh.draft.name = "Something"
        #expect(fresh.hasUnsavedChanges)
    }

    @Test("A name Outlook would refuse is caught before sending, and says why")
    func longNameCaughtLocally() async throws {
        let fake = FakeGraph()
        let model = await editor(fake: fake)
        model.draft.name = String(repeating: "x", count: 300)
        model.draft.conditions = [.subject(StringMatch("x"))]
        model.draft.actions = [.markAsRead(true)]

        #expect(await model.save() == nil)
        #expect(model.issues.contains { $0.message.contains("256") })
        #expect(fake.writes.isEmpty)
    }

    @Test("A refusal from Outlook itself reaches the editor in plain words")
    func providerErrorReachesTheEditor() async throws {
        let fake = FakeGraph()
        fake.inject(.init(method: "POST", status: 400, code: "MessageRuleValidationError",
            message: "ErrorCode: 'InvalidAddress', Message: 'The address isn't valid.', Field: 'Action.ForwardTo', Value: ':x'."))
        let model = await editor(fake: fake)
        model.draft.name = "Forward"
        model.draft.conditions = [.subject(StringMatch("x"))]
        model.draft.actions = [.forward([MailAddress("someone@example.com")])]

        #expect(await model.save() == nil)
        #expect(model.errorMessage?.contains("forwarding address") == true)
    }
}

struct FailingDirectory: FolderDirectory {
    func folders() async throws -> [MailboxFolder] { throw URLError(.notConnectedToInternet) }
    func name(forID id: String) async throws -> String? { nil }
    func id(forName name: String) async throws -> String? { nil }
}
