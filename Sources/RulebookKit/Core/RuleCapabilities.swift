import Foundation

/// What one provider's rule engine can actually express.
///
/// Every mapper publishes one of these. ``RuleCompatibility`` checks a neutral
/// rule against it *before* any network call, so "this provider cannot do
/// that" is a local, explainable answer rather than an opaque 400.
public struct RuleCapabilities: Hashable, Sendable {
    public var provider: ProviderID
    public var conditions: Set<ConditionKind>
    public var actions: Set<ActionKind>
    /// Text match modes beyond `.contains`.
    public var matchModes: Set<MatchMode>
    /// Whether the provider supports a rule-level "any of these conditions".
    public var matchStrategies: Set<MatchStrategy>
    /// Whether the provider has a native concept of exceptions.
    public var supportsExceptions: Bool
    /// Whether rules run in a defined, editable order.
    public var supportsOrdering: Bool
    /// Whether a rule can exist but be switched off.
    public var supportsDisabling: Bool
    /// Whether a rule can name a header to test, vs. searching all headers.
    public var supportsNamedHeaders: Bool
    /// Whether a yes/no test can be set to "no" ("has no attachment"). Outlook
    /// stores a false test as no test, so the rule would match every message.
    public var supportsNegatedTests: Bool

    public init(
        provider: ProviderID,
        conditions: Set<ConditionKind>,
        actions: Set<ActionKind>,
        matchModes: Set<MatchMode> = [.contains],
        matchStrategies: Set<MatchStrategy> = [.all],
        supportsExceptions: Bool = false,
        supportsOrdering: Bool = false,
        supportsDisabling: Bool = false,
        supportsNamedHeaders: Bool = false,
        supportsNegatedTests: Bool = true
    ) {
        self.provider = provider
        self.conditions = conditions
        self.actions = actions
        self.matchModes = matchModes
        self.matchStrategies = matchStrategies
        self.supportsExceptions = supportsExceptions
        self.supportsOrdering = supportsOrdering
        self.supportsDisabling = supportsDisabling
        self.supportsNamedHeaders = supportsNamedHeaders
        self.supportsNegatedTests = supportsNegatedTests
    }

    /// The local stores accept anything, so a rule can be authored and kept
    /// before a target provider is chosen.
    public static let unrestricted = RuleCapabilities(
        provider: .local,
        conditions: Set(ConditionKind.allCases),
        actions: Set(ActionKind.allCases),
        matchModes: Set(MatchMode.allCases),
        matchStrategies: Set(MatchStrategy.allCases),
        supportsExceptions: true,
        supportsOrdering: true,
        supportsDisabling: true,
        supportsNamedHeaders: true,
        supportsNegatedTests: true
    )
}

/// Checks a neutral rule against one provider's limits.
public enum RuleCompatibility {

    public static func check(_ rule: MailRule, against capabilities: RuleCapabilities) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        let provider = capabilities.provider.rawValue

        func unsupported(_ what: String) {
            issues.append(ValidationIssue(
                severity: .error, rule: rule.name,
                message: "\(provider) does not support \(what)."
            ))
        }

        for (condition, isException) in rule.conditions.map({ ($0, false) }) + rule.exceptions.map({ ($0, true) }) {
            if !capabilities.conditions.contains(condition.kind) {
                unsupported("the condition \"\(condition.description)\"")
                continue
            }
            switch condition {
            case .from(let m), .recipient(let m), .subject(let m),
                 .body(let m), .subjectOrBody(let m):
                if !capabilities.matchModes.contains(m.mode) {
                    unsupported("the \(m.mode.rawValue) match mode")
                }
            case .header(let name, let m):
                if !capabilities.matchModes.contains(m.mode) {
                    unsupported("the \(m.mode.rawValue) match mode")
                }
                if name != nil && !capabilities.supportsNamedHeaders {
                    unsupported("testing a named header")
                }
            case .rawQuery(let queryProvider, _) where queryProvider != capabilities.provider:
                unsupported("a raw \(queryProvider.rawValue) query")
            case .hasAttachment(false), .messageKind(_, false):
                guard !capabilities.supportsNegatedTests else { break }
                let positive: RuleCondition = switch condition {
                case .messageKind(let kind, _): .messageKind(kind, true)
                default: .hasAttachment(true)
                }
                issues.append(ValidationIssue(
                    severity: .error, rule: rule.name,
                    message: "\(provider) ignores a test for \u{201C}\(condition.description)\u{201D}, so this rule would apply to every message.",
                    remedy: "Add \u{201C}\(positive.description)\u{201D} as \(isException ? "a condition" : "an exception") instead; that means the same thing."
                ))
            default:
                break
            }
        }

        for action in rule.actions where !capabilities.actions.contains(action.kind) {
            // Where a refusal has a portable alternative, say so here too —
            // this check runs before the mapper and is what a UI shows first.
            let remedy = (action.kind == .stopProcessing && !capabilities.supportsOrdering)
                ? "Add an exception to the later rules instead; that means the same thing everywhere."
                : nil
            issues.append(ValidationIssue(
                severity: .error, rule: rule.name,
                message: "\(provider) does not support the action \"\(action.description)\".",
                remedy: remedy
            ))
        }

        if !rule.exceptions.isEmpty && !capabilities.supportsExceptions {
            unsupported("rule exceptions")
        }
        if !capabilities.matchStrategies.contains(rule.match) {
            unsupported("matching \"\(rule.match.rawValue)\" of the conditions")
        }
        if !rule.isEnabled && !capabilities.supportsDisabling {
            issues.append(ValidationIssue(
                severity: .warning, rule: rule.name,
                message: "\(provider) cannot store a disabled rule; it would be created active."
            ))
        }
        if rule.order != nil && !capabilities.supportsOrdering {
            issues.append(ValidationIssue(
                severity: .warning, rule: rule.name,
                message: "\(provider) has no rule ordering; `order` will be ignored."
            ))
        }

        return issues
    }
}
