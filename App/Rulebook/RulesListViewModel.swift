import Foundation
import Observation
import RulebookKit

/// Backs the rules list. Knows nothing about Graph or MSAL — it holds
/// `any RuleStore`, so previews inject `InMemoryRuleStore` and ship injects
/// `GraphRuleStore` with no change here.
@MainActor
@Observable
final class RulesListViewModel {

    enum Mode: Equatable { case normal, select, reorder }
    enum Filter: Equatable, CaseIterable { case all, enabled, disabled

        var label: String {
            switch self {
            case .all: "All"
            case .enabled: "Enabled"
            case .disabled: "Disabled"
            }
        }
    }

    // MARK: - State

    private(set) var rules: [MailRule] = []
    private(set) var issues: [RuleIssue] = []
    private(set) var isLoading = false
    /// The folder tree from the last load, so issues can be recomputed after
    /// a local change without another fetch.
    private var folderTree: [MailboxFolder]?
    /// Bumped by every load; a response that finishes after a newer one
    /// started is dropped instead of overwriting it.
    private var loadGeneration = 0
    private(set) var lastSync: Date?
    var errorMessage: String? {
        didSet { if errorMessage == nil { needsSignIn = false } }
    }

    /// The last error was the token cache having no usable sign-in, so the
    /// alert offers Sign in rather than just OK.
    private(set) var needsSignIn = false

    /// Every failure that reaches the alert goes through here, so a lapsed
    /// sign-in is recognised whichever call happened to hit it first.
    func report(_ error: Error) {
        errorMessage = error.localizedDescription
        if case .signInRequired? = error as? MSALTokenProvider.AuthError {
            needsSignIn = true
        }
    }

    /// Rules the user changed that haven't reached the server.
    ///
    /// There is no offline mode — but a network blip must not silently undo
    /// someone's edit, which is what rolling back on failure does. The local
    /// value is kept and the rule is flagged; a refresh won't clobber it, and
    /// the user can retry or discard. Held in memory only: it lasts while the
    /// app is open, which is what the banner says.
    private(set) var pending: [String: MailRule] = [:]
    private(set) var isRetrying = false

    var hasPending: Bool { !pending.isEmpty }

    var pendingTitle: String {
        pending.count == 1 ? "1 change not saved" : "\(pending.count) changes not saved"
    }

    func isPending(_ rule: MailRule) -> Bool {
        rule.id.map { pending.keys.contains($0) } ?? false
    }

    var query = ""
    var filter: Filter = .all
    var issuesOnly = false
    var mode: Mode = .normal

    /// The entitlement. `nil` means unrestricted — the CLI harness and the
    /// tests construct the view model without one, and neither sells anything.
    var pro: ProStore?

    /// Set by ``requirePro(_:)`` when a write is refused; the list view watches
    /// it and presents the sheet. Keeping it here rather than in each view is
    /// what makes the gate one list instead of scattered checks.
    var paywall: PaywallTrigger?
    var selection: Set<String> = []

    let profile: ProviderProfile
    private let store: any RuleStore
    private let folders: any FolderDirectory

    /// Hands the editor the same store and profile this list is bound to, so a
    /// screen never has to reach for a concrete provider.
    func makeEditor(for rule: MailRule? = nil) -> RuleEditorModel {
        RuleEditorModel(
            editing: rule, store: store, folders: folders, profile: profile,
            nextOrder: (rules.compactMap(\.order).max() ?? 0) + 1
        )
    }

    init(
        store: any RuleStore,
        folders: any FolderDirectory,
        profile: ProviderProfile = ProviderCatalog.outlook
    ) {
        self.store = store
        self.folders = folders
        self.profile = profile
    }

    // MARK: - Entitlement

    /// Reading is free; writing is not. Every path that mutates the mailbox
    /// calls this first, so the set of paid actions is this file's guard
    /// statements and nothing else.
    ///
    /// Returns true when the caller may proceed. When it returns false it has
    /// already raised the paywall, so callers just return.
    /// True when writes are gated. Drives the lock hints on paid controls, so
    /// the paywall confirms something the user already expected rather than
    /// being the first they hear of it.
    var isLocked: Bool {
        guard let pro else { return false }
        return !pro.isPro
    }

    @discardableResult
    func requirePro(_ trigger: PaywallTrigger) -> Bool {
        guard let pro else { return true }
        guard !pro.isPro else { return true }
        paywall = trigger
        return false
    }

    // MARK: - Derived

    var visibleRules: [MailRule] {
        rules.filter { rule in
            matchesQuery(rule) && matchesFilter(rule) && (!issuesOnly || issue(for: rule) != nil)
        }
    }

    var enabledCount: Int { rules.filter(\.isEnabled).count }

    private var primaryIssues: [RuleIssue] {
        rules.compactMap(issue(for:))
    }

    var errorCount: Int { primaryIssues.filter { $0.level == .error }.count }
    var warningCount: Int { primaryIssues.filter { $0.level == .warning }.count }

    /// The banner headline. Errors lead — a broken rule is losing mail now.
    var attentionTitle: String? {
        guard !issues.isEmpty else { return nil }
        if issuesOnly { return "Showing rules that need attention" }
        if errorCount > 0 {
            return errorCount == 1 ? "1 rule isn't working" : "\(errorCount) rules aren't working"
        }
        return warningCount == 1 ? "1 rule needs attention" : "\(warningCount) rules need attention"
    }

    var attentionSubtitle: String {
        if issuesOnly { return "Tap to show all rules again" }
        if errorCount > 0 && warningCount > 0 {
            return "Plus \(warningCount) warning\(warningCount == 1 ? "" : "s") · tap to review"
        }
        return "Tap to review"
    }

    var attentionLevel: RuleIssue.Level { errorCount > 0 ? .error : .warning }

    /// The mailbox genuinely has no rules — a first-run state, not a dead end.
    /// Distinct from a search that matched nothing.
    var hasNoRulesAtAll: Bool { rules.isEmpty && !isLoading && errorMessage == nil }

    var isFiltering: Bool {
        issuesOnly || filter != .all || !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func clearFilters() {
        query = ""
        filter = .all
        issuesOnly = false
    }

    func issue(for rule: MailRule) -> RuleIssue? {
        guard let id = rule.id else { return nil }
        // Errors outrank warnings when a rule has both.
        let mine = issues.filter { $0.ruleID == id }
        return mine.first { $0.level == .error } ?? mine.first
    }

    /// One line in the provider's own words: "All of 2 conditions → move to …".
    func summary(for rule: MailRule) -> String {
        let count = rule.conditions.count
        let head = count == 0
            ? "Every message"
            : "\(rule.match == .all ? "All" : "Any") of \(count) condition\(count == 1 ? "" : "s")"
        let tail = rule.actions.map { profile.phrase(for: $0) }.joined(separator: ", ")
        return tail.isEmpty ? head : "\(head) → \(tail)"
    }

    func orderLabel(for rule: MailRule) -> String {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return "—" }
        return String(format: "%02d", index + 1)
    }

    // MARK: - Loading

    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            let loaded = try await store.listRules()
            // Fetching the folder tree is what makes the missing-folder check
            // possible; a failure there must not hide the rules themselves.
            let tree = try? await folders.folders()
            guard generation == loadGeneration else { return }

            // A rule deleted elsewhere can't take a pending change any more.
            let ids = Set(loaded.compactMap(\.id))
            pending = pending.filter { ids.contains($0.key) }
            // A refresh must not overwrite an edit that hasn't been pushed yet.
            rules = loaded.map { server in
                server.id.flatMap { pending[$0] } ?? server
            }
            folderTree = tree
            recomputeIssues()
            lastSync = .now
        } catch {
            guard generation == loadGeneration else { return }
            // Keep whatever is on screen: stale rules are still the last known
            // truth, and they're still running on the server.
            report(error)
        }
    }

    private func recomputeIssues() {
        issues = RuleDiagnostics.check(rules, folders: folderTree)
    }

    /// The editor saved `rule`: it is now the server's truth, and any older
    /// unsent copy of it must not be retried over the top.
    func noteSaved(_ rule: MailRule) {
        guard let id = rule.id else { return }
        pending[id] = nil
        if let index = rules.firstIndex(where: { $0.id == id }) {
            rules[index] = rule
        }
        recomputeIssues()
    }

    // MARK: - Mutation

    func setEnabled(_ isEnabled: Bool, on rule: MailRule) async {
        guard requirePro(.toggle) else { return }
        guard let id = rule.id, !rule.status.isReadOnly else { return }
        var patch = rule
        patch.isEnabled = isEnabled
        await write(id: id, patch: patch)
        recomputeIssues()
    }

    /// Deletes are the one write that is NOT kept locally on failure: a rule
    /// that looks gone but is still filing mail is the worst lie to tell.
    func delete(_ rule: MailRule) async {
        guard requirePro(.delete) else { return }
        guard let id = rule.id, !rule.status.isReadOnly else { return }
        let previous = rules
        rules.removeAll { $0.id == id }
        do {
            try await store.deleteRule(id: id)
        } catch RuleStoreError.notFound {
            // Already gone (deleted in Outlook, or a retried request that had
            // in fact landed). Gone is what was asked for.
        } catch {
            rules = previous
            errorMessage = "That rule couldn't be deleted. It's still on the server and still running."
            return
        }
        pending[id] = nil
        selection.remove(id)
        recomputeIssues()
    }

    func duplicate(_ rule: MailRule) async -> MailRule? {
        guard requirePro(.duplicate) else { return nil }
        var copy = rule.writablePayload()   // clears id and provider-owned status
        copy.name = "\(rule.name) (copy)"
        copy.isEnabled = false
        do {
            let created = try await store.createRule(copy)
            await load()
            return created
        } catch {
            report(error)
            return nil
        }
    }

    // MARK: - Bulk

    /// Read-only rules are skipped rather than failing the batch — the user
    /// selected a range, they didn't single out an admin rule.
    func applyToSelection(enabled: Bool) async {
        guard requirePro(.bulk) else { return }
        for rule in selectedWritableRules {
            await setEnabled(enabled, on: rule)
        }
        endSelection()
    }

    func deleteSelection() async {
        guard requirePro(.bulk) else { return }
        for rule in selectedWritableRules {
            await delete(rule)
        }
        endSelection()
    }

    private var selectedWritableRules: [MailRule] {
        rules.filter { selection.contains($0.id ?? "") && !$0.status.isReadOnly }
    }

    func toggleSelection(_ rule: MailRule) {
        guard let id = rule.id else { return }
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    func beginSelection(with rule: MailRule) {
        mode = .select
        selection = rule.id.map { [$0] } ?? []
    }

    func endSelection() {
        mode = .normal
        selection = []
    }

    // MARK: - Reorder
    //
    // Outlook keeps positions dense, 1…N: putting a rule at position k shifts
    // the ones below it down. So a drag is one `moveRule` for the rule that
    // moved, not a renumbering of every rule in between.

    /// `source` and `destination` are offsets into ``visibleRules``, which is
    /// what the list shows; with a search or filter on, that is not ``rules``.
    func move(from source: IndexSet, to destination: Int) async {
        guard requirePro(.reorder) else { return }
        let visible = visibleRules
        let moved = source.compactMap { visible.indices.contains($0) ? visible[$0] : nil }
        guard !moved.isEmpty, !moved.contains(where: \.status.isReadOnly) else { return }

        // Where the drop lands in the full list: before the visible row it was
        // dropped on, or just after the last visible row.
        let movedIDs = Set(moved.compactMap(\.id))
        var reordered = rules.filter { !movedIDs.contains($0.id ?? "") }
        let anchor = visible[destination...].first { !movedIDs.contains($0.id ?? "") }
        let insertAt: Int
        if let anchor, let index = reordered.firstIndex(where: { $0.id == anchor.id }) {
            insertAt = index
        } else if let last = visible.last(where: { !movedIDs.contains($0.id ?? "") }),
                  let index = reordered.firstIndex(where: { $0.id == last.id }) {
            insertAt = index + 1
        } else {
            insertAt = reordered.count
        }
        reordered.insert(contentsOf: moved, at: insertAt)
        guard reordered.map(\.id) != rules.map(\.id) else { return }

        // Show the result immediately; the server catches up.
        rules = reordered
        do {
            // Top-down, so each move lands where the final order says.
            for (index, rule) in reordered.enumerated() where movedIDs.contains(rule.id ?? "") {
                try await store.moveRule(id: rule.id!, toPosition: index + 1)
            }
        } catch {
            report(error)
        }
        // Either way, take the server's numbering as the truth.
        await load()
    }

    /// The fix for a "never runs" warning: hoist the rule to the top, above
    /// whatever stopped it.
    func hoist(_ rule: MailRule) async {
        guard requirePro(.reorder) else { return }
        guard let id = rule.id, let index = rules.firstIndex(where: { $0.id == id }), index > 0 else { return }
        var reordered = rules
        reordered.move(fromOffsets: IndexSet(integer: index), toOffset: 0)
        rules = reordered
        do {
            try await store.moveRule(id: id, toPosition: 1)
        } catch {
            report(error)
        }
        await load()
    }

    // MARK: - Private

    /// Applies the change locally first, then pushes. On failure the local
    /// value STAYS and the rule is marked pending — never rolled back.
    private func write(id: String, patch: MailRule) async {
        if let index = rules.firstIndex(where: { $0.id == id }) {
            rules[index] = patch
        }
        // Leave the position out: the copy's order may be stale, and on Graph
        // writing it would move the rule.
        var patch = patch
        patch.order = nil
        do {
            let updated = try await store.updateRule(id: id, with: patch)
            if let index = rules.firstIndex(where: { $0.id == id }) {
                rules[index] = updated
            }
            pending[id] = nil
        } catch {
            pending[id] = patch
            errorMessage = nil   // the pending banner says it better than an alert
        }
    }

    /// Push every pending change. Anything that fails again stays pending.
    func retryPending() async {
        guard !pending.isEmpty else { return }
        isRetrying = true
        defer { isRetrying = false }

        for (id, patch) in pending {
            var patch = patch
            patch.order = nil
            do {
                let updated = try await store.updateRule(id: id, with: patch)
                if let index = rules.firstIndex(where: { $0.id == id }) {
                    rules[index] = updated
                }
                pending[id] = nil
            } catch RuleStoreError.notFound {
                // Deleted elsewhere: nothing left to save it to. Dropping it
                // keeps one dead entry from blocking the rest.
                pending[id] = nil
                rules.removeAll { $0.id == id }
            } catch {
                // Leave it pending and stop hammering a server that's down.
                break
            }
        }
        recomputeIssues()
        if pending.isEmpty { lastSync = .now }
    }

    /// Throw away the local edits and take the server's version.
    func discardPending() async {
        pending.removeAll()
        await load()
    }

    private func matchesQuery(_ rule: MailRule) -> Bool {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return true }
        let needle = query.lowercased()
        if rule.name.lowercased().contains(needle) { return true }
        if rule.conditions.contains(where: { profile.phrase(for: $0).lowercased().contains(needle) }) { return true }
        if rule.actions.contains(where: { profile.phrase(for: $0).lowercased().contains(needle) }) { return true }
        return false
    }

    private func matchesFilter(_ rule: MailRule) -> Bool {
        switch filter {
        case .all: true
        case .enabled: rule.isEnabled
        case .disabled: !rule.isEnabled
        }
    }
}
