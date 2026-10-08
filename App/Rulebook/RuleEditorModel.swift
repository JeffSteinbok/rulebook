import Foundation
import Observation
import RulebookKit

/// Draft state for one rule, shared by the create flow and the editor.
///
/// Holds a `MailRule` under construction plus the provider profile that
/// constrains it. Every picker is filled from `profile.availableConditions` /
/// `availableActions` — never a hard-coded list, so a rule can only be built
/// from what the connected provider actually supports.
@MainActor
@Observable
final class RuleEditorModel {

    enum Step: Int, CaseIterable { case name = 1, conditions, actions

        var title: String {
            switch self {
            case .name: "Name the rule"
            case .conditions: "Set the conditions"
            case .actions: "Pick the actions"
            }
        }

        var nextLabel: String {
            switch self {
            case .name: "Conditions"
            case .conditions: "Actions"
            case .actions: "Save rule"
            }
        }
    }

    // MARK: - State

    var draft: MailRule
    var step: Step = .name
    private(set) var issues: [ValidationIssue] = []
    private(set) var isSaving = false
    var errorMessage: String?

    let profile: ProviderProfile
    let isEditing: Bool
    /// What the server holds, for the clear-collection problem below.
    private let original: MailRule?
    private let store: any RuleStore
    private let folders: any FolderDirectory

    private(set) var availableFolders: [MailboxFolder] = []

    /// - Parameter nextOrder: where a newly created rule lands in evaluation
    ///   order. It must be a real position: Outlook numbers rules from 1 and
    ///   rejects a sequence of 0 outright, and a new rule belongs after the
    ///   ones already there, not in front of them.
    init(
        editing rule: MailRule? = nil,
        store: any RuleStore,
        folders: any FolderDirectory,
        profile: ProviderProfile = ProviderCatalog.outlook,
        nextOrder: Int = 1
    ) {
        self.original = rule
        self.isEditing = rule != nil
        self.draft = rule ?? MailRule(
            name: "",
            order: nextOrder,
            isEnabled: true,
            match: .all,
            conditions: [.from(.init("", mode: .contains))],
            actions: []
        )
        self.store = store
        self.folders = folders
        self.profile = profile
        if rule != nil { self.step = .conditions }
    }

    /// Replaces the picked action of this kind, addressed by kind rather than
    /// by index so a row can never write to a stale position.
    func replaceAction(kind: ActionKind, with action: RuleAction) {
        guard let index = draft.actions.firstIndex(where: { $0.kind == kind }) else { return }
        draft.actions[index] = action
    }

    func pickedAction(of kind: ActionKind) -> RuleAction? {
        draft.actions.first { $0.kind == kind }
    }

    func loadFolders() async {
        // A failure leaves the list empty, which the editor renders as a
        // free-text folder field rather than a dead picker.
        availableFolders = (try? await folders.folders()) ?? []
    }

    // MARK: - Pickers, from the provider's capabilities

    var conditionKinds: [ConditionKind] { profile.availableConditions }
    var actionKinds: [ActionKind] { profile.availableActions }

    /// Only the match modes this provider can honour. Outlook has all four;
    /// a provider with only `.contains` shows one.
    var matchModes: [MatchMode] {
        MatchMode.allCases.filter { profile.capabilities.matchModes.contains($0) }
    }

    var supportsMatchAny: Bool { profile.capabilities.matchStrategies.contains(.any) }
    var supportsExceptions: Bool { profile.capabilities.supportsExceptions }

    func label(for kind: ConditionKind) -> String { profile.vocabulary.name(for: kind) }
    func label(for kind: ActionKind) -> String { profile.vocabulary.name(for: kind) }

    // MARK: - Conditions

    func addCondition() {
        draft.conditions.append(.subject(.init("", mode: .contains)))
    }

    func removeCondition(at index: Int) {
        guard draft.conditions.indices.contains(index) else { return }
        draft.conditions.remove(at: index)
    }

    func addException() {
        draft.exceptions.append(.from(.init("", mode: .contains)))
    }

    func removeException(at index: Int) {
        guard draft.exceptions.indices.contains(index) else { return }
        draft.exceptions.remove(at: index)
    }

    /// The joiner shown before each condition — reads as a sentence down the list.
    func joiner(at index: Int, isException: Bool) -> String {
        if isException { return index == 0 ? "SKIP IF" : "OR IF" }
        if index == 0 { return "IF" }
        return draft.match == .all ? "AND ALSO" : "OR"
    }

    // MARK: - Actions

    func isPicked(_ kind: ActionKind) -> Bool {
        draft.actions.contains { $0.kind == kind }
    }

    func toggle(_ kind: ActionKind) {
        if let index = draft.actions.firstIndex(where: { $0.kind == kind }) {
            draft.actions.remove(at: index)
        } else {
            draft.actions.append(Self.defaultAction(for: kind, folder: availableFolders.first))
        }
    }

    /// A newly-picked action needs a value; these are the neutral defaults.
    private static func defaultAction(for kind: ActionKind, folder: MailboxFolder?) -> RuleAction {
        switch kind {
        case .moveTo: .moveTo(folder ?? .named(""))
        case .copyTo: .copyTo(folder ?? .named(""))
        case .addLabel: .addLabel(.named(""))
        case .removeLabel: .removeLabel(.named(""))
        case .markAsRead: .markAsRead(true)
        case .markAsStarred: .markAsStarred(true)
        case .markImportance: .markImportance(.high)
        case .forward: .forward([])
        case .forwardAsAttachment: .forwardAsAttachment([])
        case .redirect: .redirect([])
        case .delete: .delete(permanent: false)
        case .archive: .archive
        case .markAsSpam: .markAsSpam(true)
        case .stopProcessing: .stopProcessing
        }
    }

    // MARK: - Plain words

    /// The rule as a sentence, in the provider's own vocabulary. Shown on the
    /// last step so someone can check their work without reading the form back.
    var plainWords: String {
        let conditions = draft.conditions.filter(\.hasValue)
        let head: String
        if conditions.isEmpty {
            head = "Every message"
        } else {
            let joiner = draft.match == .all ? " and " : " or "
            let phrases = conditions.map { profile.phrase(for: $0) }.joined(separator: joiner)
            head = "When a message matches \(draft.match == .all ? "all of" : "any of") — \(phrases)"
        }

        let exceptions = draft.exceptions.filter(\.hasValue)
        let unless = exceptions.isEmpty
            ? ""
            : " — unless \(exceptions.map { profile.phrase(for: $0) }.joined(separator: " or "))"

        let actions = draft.actions.isEmpty
            ? "nothing yet"
            : draft.actions.map { profile.phrase(for: $0) }.joined(separator: ", ")

        return "\(head)\(unless) — then \(actions)."
    }

    // MARK: - Validation and save

    /// Structural checks plus this provider's limits, run locally before any
    /// network call — so "Outlook can't do that" is explainable, not a 400.
    func revalidate() {
        // Updates replace what Outlook holds, so clearing every condition or
        // exception saves as cleared. The validator still warns that a rule
        // with no conditions applies to every message, and requires an action.
        issues = RuleValidator.validate(cleaned, for: profile.capabilities)
    }

    /// Whether leaving now would lose something. Cancel asks first when true.
    var hasUnsavedChanges: Bool {
        guard let original else {
            return !draft.name.trimmingCharacters(in: .whitespaces).isEmpty
                || draft.conditions.contains(where: \.hasValue) || !draft.actions.isEmpty
        }
        return cleaned != original.cleanedForComparison
    }

    var blockingIssues: [ValidationIssue] { issues.filter { $0.severity == .error } }
    var advisoryIssues: [ValidationIssue] { issues.filter { $0.severity == .warning } }
    var canSave: Bool { blockingIssues.isEmpty }

    /// Half-typed rows are dropped rather than saved empty.
    private var cleaned: MailRule {
        draft.cleanedForComparison
    }

    func advance() -> Bool {
        guard let next = Step(rawValue: step.rawValue + 1) else { return true }
        step = next
        if step == .actions { revalidate() }
        return false
    }

    func back() -> Bool {
        if isEditing { return true }
        guard let previous = Step(rawValue: step.rawValue - 1) else { return true }
        step = previous
        return false
    }

    @discardableResult
    func save() async -> MailRule? {
        revalidate()
        guard canSave else { return nil }

        isSaving = true
        defer { isSaving = false }

        do {
            if let id = draft.id {
                // An edit keeps the rule where it is now. The draft's order was
                // read when the editor opened; on Outlook, sending it would move
                // the rule back there if anything was reordered since.
                var update = cleaned
                update.order = nil
                return try await store.updateRule(id: id, with: update)
            }
            return try await store.createRule(cleaned)
        } catch let error as MappingError {
            // The mapper is the authority — it refuses cases capability checks
            // can't see, and names each one.
            if case .unsupported(let mapperIssues) = error {
                issues = mapperIssues
            } else {
                errorMessage = error.localizedDescription
            }
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
}

// MARK: - Condition helpers

extension MailRule {
    /// Trimmed name, half-typed rows dropped: what saving would send.
    var cleanedForComparison: MailRule {
        var rule = self
        rule.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        rule.conditions = conditions.filter(\.hasValue)
        rule.exceptions = exceptions.filter(\.hasValue)
        return rule
    }
}

extension RuleCondition {
    /// Whether this condition carries enough to be worth saving.
    var hasValue: Bool {
        switch self {
        case .from(let m), .recipient(let m), .subject(let m),
             .body(let m), .subjectOrBody(let m), .header(_, let m):
            return m.anyOf.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        case .hasLabels(let values):
            return !values.isEmpty
        case .rawQuery(_, let query):
            return !query.isEmpty
        case .size(let size):
            return size.minimumBytes != nil || size.maximumBytes != nil
        default:
            return true
        }
    }

    /// The text match inside, for the kinds that have one.
    var stringMatch: StringMatch? {
        switch self {
        case .from(let m), .recipient(let m), .subject(let m),
             .body(let m), .subjectOrBody(let m), .header(_, let m):
            return m
        default:
            return nil
        }
    }

    /// Rebuilt with a new match, preserving kind. Used by the editor's pickers.
    func replacing(match: StringMatch) -> RuleCondition {
        switch self {
        case .from: .from(match)
        case .recipient: .recipient(match)
        case .subject: .subject(match)
        case .body: .body(match)
        case .subjectOrBody: .subjectOrBody(match)
        case .header(let name, _): .header(name: name, match: match)
        default: self
        }
    }

    /// A blank condition of the given kind, for when the field picker changes.
    static func blank(_ kind: ConditionKind) -> RuleCondition {
        switch kind {
        case .from: .from(.init("", mode: .contains))
        case .recipient: .recipient(.init("", mode: .contains))
        case .subject: .subject(.init("", mode: .contains))
        case .body: .body(.init("", mode: .contains))
        case .subjectOrBody: .subjectOrBody(.init("", mode: .contains))
        // nil, not "": a header *name* is something Outlook can't test, and an
        // empty one was being refused as if it were.
        case .header: .header(name: nil, match: .init("", mode: .contains))
        case .hasAttachment: .hasAttachment(true)
        case .size: .size(.init(minimumBytes: nil, maximumBytes: 5_242_880))
        case .importance: .importance(.high)
        case .sensitivity: .sensitivity(.normal)
        case .hasLabels: .hasLabels([])
        case .addressed: .addressed(.toMe)
        case .messageKind: .messageKind(.meetingRequest, true)
        case .actionFlag: .actionFlag(.any)
        case .rawQuery: .rawQuery(provider: .microsoft, query: "")
        }
    }
}
