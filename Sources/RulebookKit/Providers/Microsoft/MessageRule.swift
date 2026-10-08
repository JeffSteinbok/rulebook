import Foundation

/// Mirrors Microsoft Graph `messageRule`.
///
/// Graph only supports message rules on the **Inbox** folder
/// (`/me/mailFolders/inbox/messageRules`).
public struct MessageRule: Codable, Hashable, Sendable, Identifiable {
    /// Server-assigned. `nil` for a rule that has not been created yet.
    public var id: String?

    public var displayName: String

    /// Evaluation order, 1-based. Graph keeps these dense (1…N): writing *k*
    /// inserts the rule at *k* and shifts the rest down, and anything past
    /// the end lands at N+1. `nil` in a PATCH leaves the position alone;
    /// a POST must carry one, or Graph answers 400.
    public var sequence: Int?

    public var isEnabled: Bool?

    /// Read-only on Graph: `true` when the rule is in an error state.
    public private(set) var hasError: Bool?

    /// Read-only on Graph: `true` when the rule cannot be modified through the API.
    public private(set) var isReadOnly: Bool?

    public var conditions: MessageRulePredicates?
    public var exceptions: MessageRulePredicates?
    public var actions: MessageRuleActions?

    public init(
        id: String? = nil,
        displayName: String,
        sequence: Int?,
        isEnabled: Bool? = true,
        conditions: MessageRulePredicates? = nil,
        exceptions: MessageRulePredicates? = nil,
        actions: MessageRuleActions? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.sequence = sequence
        self.isEnabled = isEnabled
        self.conditions = conditions
        self.exceptions = exceptions
        self.actions = actions
    }

    /// A copy with the server-owned properties stripped, safe to send as a
    /// POST or PATCH body. `id` lives in the URL, and `hasError`/`isReadOnly`
    /// are rejected as read-only if written back.
    ///
    /// Nil optionals are omitted by `JSONEncoder`, which is exactly the
    /// semantics PATCH wants: only the properties you set are changed.
    private enum CodingKeys: String, CodingKey {
        case id, displayName, sequence, isEnabled, hasError, isReadOnly, conditions, exceptions, actions
    }

    /// Tolerant on the way in: one rule with an absent name or sequence must
    /// not make the whole list unreadable.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        sequence = try c.decodeIfPresent(Int.self, forKey: .sequence)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled)
        hasError = try c.decodeIfPresent(Bool.self, forKey: .hasError)
        isReadOnly = try c.decodeIfPresent(Bool.self, forKey: .isReadOnly)
        conditions = try c.decodeIfPresent(MessageRulePredicates.self, forKey: .conditions)
        exceptions = try c.decodeIfPresent(MessageRulePredicates.self, forKey: .exceptions)
        actions = try c.decodeIfPresent(MessageRuleActions.self, forKey: .actions)
    }

    public func writablePayload() -> MessageRule {
        var copy = self
        copy.id = nil
        copy.hasError = nil
        copy.isReadOnly = nil
        return copy
    }
}
