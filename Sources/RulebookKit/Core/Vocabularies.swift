import Foundation

// Shared helpers for wording values inside a phrase.
enum Phrasing {
    static func quoted(_ values: [String]) -> String {
        values.map { "‘\($0)’" }.joined(separator: " or ")
    }

    static func addresses(_ values: [MailAddress]) -> String {
        values.map { $0.name ?? $0.address }.joined(separator: ", ")
    }

    /// Byte counts in the units each product shows.
    static func kilobytes(_ bytes: Int) -> String { "\(bytes / 1024) KB" }

    static func bytes(_ value: Int) -> String {
        value >= 1_048_576 ? "\(value / 1_048_576) MB" : "\(value / 1024) KB"
    }
}

// MARK: - Outlook

/// Wording taken from Outlook's own rules editor.
public struct OutlookVocabulary: ProviderVocabulary {
    public init() {}

    public func name(for kind: ConditionKind) -> String {
        switch kind {
        case .from: "From"
        case .recipient: "Sent to"
        case .subject: "Subject includes"
        case .body: "Message body includes"
        case .subjectOrBody: "Subject or body includes"
        case .header: "Message header includes"
        case .hasAttachment: "Has attachment"
        case .size: "Message size"
        case .importance: "Importance"
        case .sensitivity: "Sensitivity"
        case .hasLabels: "Categorized as"
        case .addressed: "Recipient line"
        case .messageKind: "Message type"
        case .actionFlag: "Marked with"
        case .rawQuery: "Search query"
        }
    }

    public func name(for kind: ActionKind) -> String {
        switch kind {
        case .moveTo: "Move to"
        case .copyTo: "Copy to"
        case .addLabel: "Categorize as"
        case .removeLabel: "Remove category"
        case .markAsRead: "Mark as read"
        case .markAsStarred: "Flag"
        case .markImportance: "Mark with importance"
        case .forward: "Forward to"
        case .forwardAsAttachment: "Forward as attachment to"
        case .redirect: "Redirect to"
        case .delete: "Delete"
        case .archive: "Archive"
        case .markAsSpam: "Mark as junk"
        case .stopProcessing: "Stop processing more rules"
        }
    }

    public func phrase(for condition: RuleCondition) -> String {
        switch condition {
        case .from(let m): "From \(Phrasing.quoted(m.anyOf))"
        case .recipient(let m): "Sent to \(Phrasing.quoted(m.anyOf))"
        case .subject(let m): "Subject includes \(Phrasing.quoted(m.anyOf))"
        case .body(let m): "Message body includes \(Phrasing.quoted(m.anyOf))"
        case .subjectOrBody(let m): "Subject or body includes \(Phrasing.quoted(m.anyOf))"
        case .header(let name, let m):
            name.map { "Header \($0) includes \(Phrasing.quoted(m.anyOf))" }
                ?? "Message header includes \(Phrasing.quoted(m.anyOf))"
        case .hasAttachment(let value): value ? "Has an attachment" : "Has no attachment"
        case .size(let size):
            switch (size.minimumBytes, size.maximumBytes) {
            case (let low?, let high?): "Message size between \(Phrasing.kilobytes(low)) and \(Phrasing.kilobytes(high))"
            case (let low?, nil): "Message size at least \(Phrasing.kilobytes(low))"
            case (nil, let high?): "Message size at most \(Phrasing.kilobytes(high))"
            case (nil, nil): "Message size"
            }
        case .importance(let value): "Importance is \(value.rawValue.capitalized)"
        case .sensitivity(let value): "Sensitivity is \(value.rawValue.capitalized)"
        case .hasLabels(let values): "Categorized as \(Phrasing.quoted(values))"
        case .addressed(let scope):
            switch scope {
            case .toMe: "I'm on the To line"
            case .ccMe: "I'm on the Cc line"
            case .toOrCcMe: "I'm on the To or Cc line"
            case .onlyToMe: "I'm the only recipient"
            case .notToMe: "I'm not on the To line"
            }
        case .messageKind(let kind, let expected):
            expected
                ? "Message type is \(kind.rawValue.outlookMessageType)"
                : "Message type is not \(kind.rawValue.outlookMessageType)"
        case .actionFlag(let value): "Marked with \(value.rawValue.humanised)"
        case .rawQuery(let provider, let query): "\(provider.rawValue) query: \(query)"
        }
    }

    public func phrase(for action: RuleAction) -> String {
        switch action {
        case .moveTo(let f): "Move to ‘\(f.label)’"
        case .copyTo(let f): "Copy to ‘\(f.label)’"
        case .addLabel(let f): "Categorize as ‘\(f.label)’"
        case .removeLabel(let f): "Remove the category ‘\(f.label)’"
        case .markAsRead(let v): v ? "Mark as read" : "Mark as unread"
        case .markAsStarred(let v): v ? "Flag the message" : "Clear the flag"
        case .markImportance(let v): "Mark with \(v.rawValue) importance"
        case .forward(let to): "Forward to \(Phrasing.addresses(to))"
        case .forwardAsAttachment(let to): "Forward as attachment to \(Phrasing.addresses(to))"
        case .redirect(let to): "Redirect to \(Phrasing.addresses(to))"
        case .delete(let permanent): permanent ? "Delete permanently" : "Delete"
        case .archive: "Archive"
        case .markAsSpam(let v): v ? "Mark as junk" : "Never mark as junk"
        case .stopProcessing: "Stop processing more rules"
        }
    }
}

// MARK: - Neutral

/// Provider-independent wording, used by the local stores and anywhere no
/// provider has been chosen yet.
public struct NeutralVocabulary: ProviderVocabulary {
    public init() {}

    public func name(for kind: ConditionKind) -> String { kind.rawValue.humanised }
    public func name(for kind: ActionKind) -> String { kind.rawValue.humanised }
    public func phrase(for condition: RuleCondition) -> String { condition.description }
    public func phrase(for action: RuleAction) -> String { action.description }
}

// MARK: - String shaping

extension String {
    /// "subjectOrBody" -> "Subject or body"
    var humanised: String {
        var words = ""
        for character in self {
            if character.isUppercase && !words.isEmpty {
                words.append(" ")
                words.append(contentsOf: character.lowercased())
            } else {
                words.append(character)
            }
        }
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    var outlookMessageType: String {
        switch self {
        case "meetingRequest": "Meeting request"
        case "meetingResponse": "Meeting response"
        case "readReceipt": "Read receipt"
        case "nonDeliveryReport": "Non-delivery report"
        case "automaticReply": "Automatic reply"
        case "automaticForward": "Automatic forward"
        case "permissionControlled": "Permission controlled"
        case "approvalRequest": "Approval request"
        default: humanised
        }
    }
}
