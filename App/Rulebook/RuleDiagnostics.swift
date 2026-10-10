import Foundation
import RulebookKit

/// A problem with a rule, surfaced in the list and on the detail screen.
///
/// Only `.serverError` comes from the provider. The other two are local
/// analysis — which is the point: the README notes a rule can reference a
/// deleted folder and still be reported healthy, silently dropping mail.
///
/// This type is a candidate to move into RulebookKit next to `RuleValidator`
/// (see "Gaps" in the spec) — it's provider-neutral policy, and the CLI would
/// get `rulebook doctor` for free.
struct RuleIssue: Identifiable, Hashable {
    enum Level: Hashable { case error, warning }

    enum Kind: Hashable {
        case serverError
        case missingFolder(named: String)
        case neverRuns(blockedBy: String)
        /// No conditions, so it acts on every incoming message. Usually a
        /// mistake, and exactly what a "has no attachment" rule saved before
        /// 1.1 became: Outlook stored the false test as no test.
        case appliesToEverything(destructive: Bool)
    }

    let ruleID: String
    let kind: Kind

    var id: String { "\(ruleID)-\(kind.hashValue)" }

    var level: Level {
        switch kind {
        case .serverError, .missingFolder: .error
        case .appliesToEverything(let destructive): destructive ? .error : .warning
        case .neverRuns: .warning
        }
    }

    var label: String {
        switch kind {
        case .serverError: "Rule is in error"
        case .missingFolder: "Folder is missing"
        case .neverRuns: "Never runs"
        case .appliesToEverything: "Runs on every message"
        }
    }

    var detail: String {
        switch kind {
        case .serverError:
            "Exchange reports hasError on this rule. Open it and save again to reinstate it on the server."
        case .missingFolder(let name):
            "The folder “\(name)” is no longer in this mailbox, so matching mail silently stays in the inbox. Exchange still reports this rule as healthy. Pick a new folder."
        case .neverRuns(let blocker):
            "“\(blocker)” stops processing before this rule is reached. Move it above that rule to make it run."
        case .appliesToEverything:
            "This rule has no conditions, so it acts on every message that arrives. If it was meant for only some messages — say, ones without an attachment — add a condition, or add the opposite as an exception."
        }
    }

    var fixTitle: String {
        switch kind {
        case .serverError: "Save to the server again"
        case .missingFolder: "Choose a folder"
        case .neverRuns: "Move this rule up"
        case .appliesToEverything: "Add a condition"
        }
    }
}

enum RuleDiagnostics {

    /// - Parameters:
    ///   - rules: in evaluation order, as `listRules()` returns them.
    ///   - folders: the mailbox's real folders, from `FolderDirectory.folders()`,
    ///     or nil when they couldn't be fetched. Unknown is not empty: with no
    ///     folder list, every filing rule would otherwise be reported missing.
    static func check(_ rules: [MailRule], folders: [MailboxFolder]?) -> [RuleIssue] {
        var issues: [RuleIssue] = []

        let knownIDs = Set((folders ?? []).compactMap(\.id))
        let knownNames = Set((folders ?? []).compactMap { $0.name?.lowercased() })

        /// A referenced folder counts as present if either half resolves —
        /// rules store an id, but a locally-authored rule may only have a name.
        func exists(_ folder: MailboxFolder) -> Bool {
            if let id = folder.id, knownIDs.contains(id) { return true }
            if let name = folder.name, knownNames.contains(name.lowercased()) { return true }
            return false
        }

        // The first rule that halts processing shadows everything after it.
        var blocker: MailRule?

        for rule in rules {
            guard let id = rule.id else { continue }

            if rule.status.hasError {
                issues.append(.init(ruleID: id, kind: .serverError))
            }

            for action in rule.actions where folders != nil {
                switch action {
                case .moveTo(let folder), .copyTo(let folder):
                    if !exists(folder) {
                        issues.append(.init(ruleID: id, kind: .missingFolder(named: folder.label)))
                    }
                default:
                    break
                }
            }

            // A bare "stop processing" with no conditions is a deliberate
            // backstop, handled as a blocker below, not a mistake.
            if rule.isEnabled, rule.conditions.isEmpty,
               rule.actions.contains(where: { $0.kind != .stopProcessing }) {
                let destructive = rule.actions.contains {
                    [.delete, .forward, .forwardAsAttachment, .redirect, .moveTo].contains($0.kind)
                }
                issues.append(.init(ruleID: id, kind: .appliesToEverything(destructive: destructive)))
            }

            if let blocker, rule.isEnabled {
                issues.append(.init(ruleID: id, kind: .neverRuns(blockedBy: blocker.name)))
            }

            // A disabled rule doesn't shadow anything, and an unconditional
            // stop is the only kind we can be certain about — a rule with
            // conditions may or may not fire for a given message.
            if blocker == nil,
               rule.isEnabled,
               rule.conditions.isEmpty,
               rule.actions.contains(where: { $0.kind == .stopProcessing }) {
                blocker = rule
            }
        }

        return issues
    }
}
