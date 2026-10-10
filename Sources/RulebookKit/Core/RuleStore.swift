import Foundation

/// CRUD over one mailbox's rules, in the neutral model.
///
/// Every backend conforms: Microsoft 365 today, any provider added later, and
/// the local JSON/in-memory stores. Call sites — the iOS app, the CLI — only
/// ever see ``MailRule``.
public protocol RuleStore: Sendable {
    /// What this backend can express. Check a rule against it before writing.
    var capabilities: RuleCapabilities { get }

    /// Every rule, in evaluation order.
    func listRules() async throws -> [MailRule]
    func rule(id: String) async throws -> MailRule

    /// A rule with no `order` goes after every existing rule.
    func createRule(_ rule: MailRule) async throws -> MailRule

    /// Replaces the rule's name, state, conditions, exceptions and actions
    /// with `rule`'s, so an empty list clears what was there. A `nil` order
    /// leaves the rule where it is.
    func updateRule(id: String, with rule: MailRule) async throws -> MailRule

    /// Moves a rule to a 1-based position. The rules it displaces shift down
    /// one place, so positions stay 1…N, which is how Outlook numbers them.
    /// A position past the end means last.
    func moveRule(id: String, toPosition position: Int) async throws

    func deleteRule(id: String) async throws
}

/// Translates between the neutral model and one provider's wire format.
public protocol RuleMapper: Sendable {
    associatedtype Native

    static var capabilities: RuleCapabilities { get }

    /// - Throws: ``MappingError/unsupported(_:)`` listing every feature the
    ///   provider cannot represent, rather than dropping them quietly.
    func encode(_ rule: MailRule) throws -> Native
    func decode(_ native: Native) throws -> MailRule
}

public extension RuleMapper {
    var capabilities: RuleCapabilities { Self.capabilities }
}

public enum MappingError: Error, LocalizedError {
    case unsupported([ValidationIssue])
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let issues):
            return issues.map(\.description).joined(separator: "\n")
        case .malformed(let detail):
            return "Could not interpret the provider's rule: \(detail)"
        }
    }
}

public enum RuleStoreError: Error, LocalizedError, Sendable {
    case notFound(id: String)
    case notAuthenticated
    /// A non-2xx response, with the provider's own error code and message.
    case provider(ProviderID, status: Int, code: String?, message: String?)
    case transport(any Error)
    case decoding(any Error)

    public var errorDescription: String? {
        switch self {
        case .notFound(let id):
            return "No rule with id \(id)."
        case .notAuthenticated:
            return "Not signed in. Run `rulebook login` first."
        case .provider(let provider, let status, let code, let message):
            if let readable = ProviderErrorText.readable(code: code, message: message) {
                return readable
            }
            let detail = [code, message].compactMap { $0 }.joined(separator: ": ")
            return detail.isEmpty
                ? "\(provider.rawValue) returned HTTP \(status)."
                : "\(provider.rawValue) returned HTTP \(status) — \(detail)"
        case .transport(let error):
            return "Network error: \(error.localizedDescription)"
        case .decoding(let error):
            return "Could not decode the provider response: \(error)"
        }
    }
}


/// Turns a provider's own error text into something worth showing a person.
///
/// Graph reports rule validation failures as one dense string:
///
///     MessageRuleValidationError: ErrorCode: 'InvalidValue',
///     Message: 'The value isn't valid.', Field: 'Sequence', Value: '0'.
///
/// The field and value are the useful parts, and "Sequence" is not a word the
/// app uses anywhere. Anything unrecognised falls through to the raw text
/// rather than being flattened into "something went wrong".
enum ProviderErrorText {

    /// Graph field names, in the vocabulary the rest of the app speaks. Graph
    /// prefixes some with where they live ("Action.MoveToFolder",
    /// "Condition.WithinSizeRange"); the prefix is dropped first.
    private static let fieldNames: [String: String] = [
        "Sequence": "evaluation order",
        "Name": "name",
        "DisplayName": "name",
        "Actions": "actions",
        "MoveToFolder": "destination folder",
        "CopyToFolder": "folder to copy to",
        "ForwardTo": "forwarding address",
        "ForwardAsAttachmentTo": "forwarding address",
        "RedirectTo": "redirect address",
        "AssignCategories": "category",
        "WithinSizeRange": "size range",
    ]

    static func readable(code: String?, message: String?) -> String? {
        switch code {
        case "ErrorItemNotFound", "ErrorMessageRuleNotFound":
            return "That rule no longer exists on the server."
        case "ErrorAccessDenied":
            return "Outlook refused access. The sign-in may not cover mail rules any more."
        case "ErrorInvalidIdMalformed":
            return "That rule\u{2019}s identifier isn\u{2019}t valid."
        case "ErrorQuotaExceeded":
            return "The mailbox has as many rules as Outlook allows."
        case "InvalidAuthenticationToken":
            return "Your sign-in has expired. Sign in to this mailbox again."
        case "UnableToDeserializePostBody", "RequestBodyRead":
            return "Outlook couldn\u{2019}t read the rule Rulebook sent. About \u{2192} Diagnostics has the details for a bug report."
        default:
            break
        }

        guard let message, let rawField = capture("Field: '", in: message) else { return nil }

        let field = rawField.split(separator: ".").last.map(String.init) ?? rawField
        let name = fieldNames[field] ?? field
        let reason = capture("Message: '", in: message, until: "', ")
        let value = capture("Value: '", in: message, until: "'.")

        switch capture("ErrorCode: '", in: message) {
        case "MissingAction":
            return "Outlook needs at least one action on a rule."
        case "StringValueTooBig":
            return "The \(name) is too long for Outlook. \(reason ?? "")".trimmingCharacters(in: .whitespaces)
        default:
            // Echo the offending value only when it's short enough to read.
            if let value, !value.isEmpty, value.count <= 40 {
                return "Outlook rejected the \(name): \u{201C}\(value)\u{201D} isn\u{2019}t allowed."
            }
            if let reason { return "Outlook rejected the \(name): \(reason)" }
            return "Outlook rejected the \(name)."
        }
    }

    private static func capture(_ prefix: String, in text: String, until terminator: String = "'") -> String? {
        guard let start = text.range(of: prefix) else { return nil }
        let rest = text[start.upperBound...]
        guard let end = rest.range(of: terminator) else { return nil }
        let value = String(rest[..<end.lowerBound])
        return value.isEmpty && terminator == "'" ? nil : value
    }
}
