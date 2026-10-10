import Foundation

public enum ProviderID: String, Codable, Hashable, Sendable, CaseIterable {
    case microsoft
    /// The local JSON/in-memory stores, which impose no provider limits.
    case local
}

/// How the conditions in a rule combine.
public enum MatchStrategy: String, Codable, Hashable, Sendable, CaseIterable {
    /// Every condition must hold.
    case all
    /// Any one condition is enough.
    case any
}

/// A mail rule, independent of any provider.
///
/// This is the model the app and the CLI work in. Each provider has a mapper
/// (``RuleMapper``) that translates to and from its own wire format, and
/// declares in ``RuleCapabilities`` what it can actually represent.
public struct MailRule: Codable, Hashable, Sendable, Identifiable {
    /// Provider-assigned. `nil` for a rule that has not been created yet.
    public var id: String?

    public var name: String

    /// Evaluation order, lowest first. `nil` where the provider has no
    /// ordering and simply applies every rule that matches.
    public var order: Int?

    public var isEnabled: Bool

    public var match: MatchStrategy

    /// Tests that select messages. An empty list matches everything.
    public var conditions: [RuleCondition]

    /// If any of these holds, the rule does not apply.
    public var exceptions: [RuleCondition]

    public var actions: [RuleAction]

    /// Set by a store when the provider reports the rule is broken or frozen.
    public var status: RuleStatus

    public init(
        id: String? = nil,
        name: String,
        order: Int? = nil,
        isEnabled: Bool = true,
        match: MatchStrategy = .all,
        conditions: [RuleCondition] = [],
        exceptions: [RuleCondition] = [],
        actions: [RuleAction] = [],
        status: RuleStatus = .init()
    ) {
        self.id = id
        self.name = name
        self.order = order
        self.isEnabled = isEnabled
        self.match = match
        self.conditions = conditions
        self.exceptions = exceptions
        self.actions = actions
        self.status = status
    }

    public func condition(_ kind: ConditionKind) -> RuleCondition? {
        conditions.first { $0.kind == kind }
    }

    public func action(_ kind: ActionKind) -> RuleAction? {
        actions.first { $0.kind == kind }
    }

    /// A copy with everything the provider owns cleared, ready to be written.
    public func writablePayload() -> MailRule {
        var copy = self
        copy.id = nil
        copy.status = RuleStatus()
        return copy
    }
}

extension MailRule {
    private enum CodingKeys: String, CodingKey {
        case id, name, order, isEnabled, match, conditions, exceptions, actions, status
    }

    /// Only `name` is required, so a hand-written rule file can leave out
    /// everything with an obvious default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decodeIfPresent(String.self, forKey: .id),
            name: try c.decode(String.self, forKey: .name),
            order: try c.decodeIfPresent(Int.self, forKey: .order),
            isEnabled: try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true,
            match: try c.decodeIfPresent(MatchStrategy.self, forKey: .match) ?? .all,
            conditions: try c.decodeIfPresent([RuleCondition].self, forKey: .conditions) ?? [],
            exceptions: try c.decodeIfPresent([RuleCondition].self, forKey: .exceptions) ?? [],
            actions: try c.decodeIfPresent([RuleAction].self, forKey: .actions) ?? [],
            status: try c.decodeIfPresent(RuleStatus.self, forKey: .status) ?? RuleStatus()
        )
    }
}

/// Provider-reported state. Read-only everywhere.
public struct RuleStatus: Codable, Hashable, Sendable {
    public var hasError: Bool
    public var isReadOnly: Bool

    public init(hasError: Bool = false, isReadOnly: Bool = false) {
        self.hasError = hasError
        self.isReadOnly = isReadOnly
    }

    public var isClean: Bool { !hasError && !isReadOnly }
}
