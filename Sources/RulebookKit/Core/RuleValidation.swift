import Foundation

/// A problem found before anything is sent to a provider.
public struct ValidationIssue: Hashable, Sendable, CustomStringConvertible {
    public enum Severity: String, Sendable { case error, warning }

    public var severity: Severity
    /// Which rule the issue belongs to — by name, since ids are absent pre-create.
    public var rule: String?
    public var message: String
    /// What to do about it, where there is a portable alternative. Shown after
    /// the message in text output; a UI can surface it as a fix-it.
    public var remedy: String?

    public init(severity: Severity, rule: String?, message: String, remedy: String? = nil) {
        self.severity = severity
        self.rule = rule
        self.message = message
        self.remedy = remedy
    }

    public var description: String {
        let subject = rule.map { "[\($0)] " } ?? ""
        let fix = remedy.map { " \($0)" } ?? ""
        return "\(severity.rawValue): \(subject)\(message)\(fix)"
    }
}

public extension Array where Element == ValidationIssue {
    var hasErrors: Bool { contains { $0.severity == .error } }
}

/// Provider-independent structural checks. Pair with
/// ``RuleCompatibility/check(_:against:)`` for provider limits.
public enum RuleValidator {

    public static func validate(_ rule: MailRule) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []

        func error(_ message: String) {
            issues.append(ValidationIssue(severity: .error, rule: rule.name, message: message))
        }
        func warn(_ message: String) {
            issues.append(ValidationIssue(severity: .warning, rule: rule.name, message: message))
        }

        if rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            error("name must not be empty.")
        }
        if let order = rule.order, order < 0 {
            error("order must be zero or greater (got \(order)).")
        }
        if rule.actions.isEmpty {
            error("A rule must specify at least one action.")
        }
        if rule.conditions.isEmpty {
            warn("No conditions set — this rule will apply to every incoming message.")
        }

        issues.append(contentsOf: validateConditions(rule.conditions, in: rule, label: "condition"))
        issues.append(contentsOf: validateConditions(rule.exceptions, in: rule, label: "exception"))
        issues.append(contentsOf: validateActions(rule))

        return issues
    }

    private static func validateConditions(
        _ conditions: [RuleCondition], in rule: MailRule, label: String
    ) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []

        func error(_ message: String) {
            issues.append(ValidationIssue(severity: .error, rule: rule.name, message: message))
        }

        for condition in conditions {
            switch condition {
            case .from(let m), .recipient(let m), .subject(let m),
                 .body(let m), .subjectOrBody(let m), .header(_, let m):
                if m.anyOf.isEmpty {
                    error("\(label) \"\(condition.kind.rawValue)\" has no values to match.")
                }
                if m.anyOf.contains(where: { $0.isEmpty }) {
                    error("\(label) \"\(condition.kind.rawValue)\" contains an empty string.")
                }
            case .size(let size):
                if let low = size.minimumBytes, let high = size.maximumBytes, low > high {
                    error("\(label) size has minimum (\(low)B) greater than maximum (\(high)B).")
                }
                if size.minimumBytes == nil && size.maximumBytes == nil {
                    error("\(label) size sets neither a minimum nor a maximum.")
                }
            case .hasLabels(let values) where values.isEmpty:
                error("\(label) \"hasLabels\" is empty.")
            case .rawQuery(_, let query) where query.isEmpty:
                error("\(label) \"rawQuery\" is empty.")
            default:
                break
            }
        }

        let kinds = conditions.map(\.kind)
        for kind in Set(kinds) where kinds.filter({ $0 == kind }).count > 1 && kind != .header {
            issues.append(ValidationIssue(
                severity: .warning, rule: rule.name,
                message: "\(label) \"\(kind.rawValue)\" appears more than once; providers may keep only one."
            ))
        }

        return issues
    }

    private static func validateActions(_ rule: MailRule) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []

        func error(_ message: String) {
            issues.append(ValidationIssue(severity: .error, rule: rule.name, message: message))
        }
        func warn(_ message: String) {
            issues.append(ValidationIssue(severity: .warning, rule: rule.name, message: message))
        }

        for action in rule.actions {
            switch action {
            case .moveTo(let folder), .copyTo(let folder),
                 .addLabel(let folder), .removeLabel(let folder):
                if (folder.id ?? "").isEmpty && (folder.name ?? "").isEmpty {
                    error("\(action.kind.rawValue) names neither a folder id nor a name.")
                }
            case .forward(let to), .forwardAsAttachment(let to), .redirect(let to):
                if to.isEmpty {
                    error("\(action.kind.rawValue) has no recipients.")
                }
                for recipient in to where recipient.address.isEmpty {
                    error("\(action.kind.rawValue) has a recipient with no address.")
                }
            default:
                break
            }
        }

        let dispositions = rule.actions.filter(\.isTerminalDisposition)
        if dispositions.count > 1 {
            warn("\(dispositions.count) actions each move the message: \(dispositions.map(\.description).joined(separator: ", ")).")
        }

        let kinds = rule.actions.map(\.kind)
        for kind in Set(kinds) where kinds.filter({ $0 == kind }).count > 1 {
            warn("action \"\(kind.rawValue)\" appears more than once.")
        }

        return issues
    }

    /// Whole-set checks, plus every per-rule check.
    public static func validate(set rules: [MailRule]) -> [ValidationIssue] {
        var issues = rules.flatMap { validate($0) }

        let ordered = rules.compactMap(\.order)
        for order in Set(ordered) where ordered.filter({ $0 == order }).count > 1 {
            let names = rules.filter { $0.order == order }.map(\.name).sorted().joined(separator: ", ")
            issues.append(ValidationIssue(
                severity: .error, rule: nil,
                message: "order \(order) is used by more than one rule: \(names)."
            ))
        }

        let names = rules.map(\.name)
        for name in Set(names).sorted() where names.filter({ $0 == name }).count > 1 {
            issues.append(ValidationIssue(
                severity: .warning, rule: nil,
                message: "\(names.filter { $0 == name }.count) rules share the name \"\(name)\"."
            ))
        }

        return issues
    }

    /// Structural checks plus the target provider's limits.
    public static func validate(_ rule: MailRule, for capabilities: RuleCapabilities) -> [ValidationIssue] {
        validate(rule) + RuleCompatibility.check(rule, against: capabilities)
    }
}
