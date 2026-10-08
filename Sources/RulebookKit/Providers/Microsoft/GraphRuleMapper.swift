import Foundation

/// Translates between ``MailRule`` and Graph's `messageRule`.
///
/// ``RuleCapabilities`` is the cheap pre-flight check; this mapper is the
/// authority. Where a capability is true only for some conditions — Graph can
/// match an exact address but not an exact subject — the check passes and
/// ``encode(_:)`` reports the specific case.
public struct GraphRuleMapper: RuleMapper {
    public typealias Native = MessageRule

    public init() {}

    public static let capabilities = RuleCapabilities(
        provider: .microsoft,
        conditions: [
            .from, .recipient, .subject, .body, .subjectOrBody, .header,
            .hasAttachment, .size, .importance, .sensitivity, .hasLabels,
            .addressed, .messageKind, .actionFlag,
        ],
        actions: [
            .moveTo, .copyTo, .addLabel, .markAsRead, .markImportance,
            .forward, .forwardAsAttachment, .redirect, .delete, .stopProcessing,
        ],
        // `.equals` holds for addresses only; `encode` rejects it elsewhere.
        matchModes: [.contains, .equals],
        matchStrategies: [.all],
        supportsExceptions: true,
        supportsOrdering: true,
        supportsDisabling: true,
        supportsNamedHeaders: false,
        // `predicates-negated.json`: false is stored as no condition at all.
        supportsNegatedTests: false
    )

    /// A `sequence` past any real mailbox's end. Graph clamps it to N+1,
    /// which is how a create appends (`Fixtures/graph/sequence.json`).
    public static let appendSequence = 2_000_000_000

    /// The largest `withinSizeRange` bound Graph accepts, in kilobytes (2 GB).
    /// It reads an absent maximum as 0, so "at least N" is sent as N…this.
    public static let largestSizeKB = 2_097_151

    // MARK: - Neutral -> Graph

    /// Every behaviour this relies on is recorded in `Fixtures/graph/` and
    /// reproduced by `FakeGraph`; see the README there.
    public func encode(_ rule: MailRule) throws -> MessageRule {
        var issues: [ValidationIssue] = []

        func reject(_ what: String, remedy: String? = nil) {
            issues.append(ValidationIssue(
                severity: .error, rule: rule.name,
                message: "Microsoft 365 cannot express \(what).",
                remedy: remedy
            ))
        }

        if rule.match == .any {
            reject("matching any of several conditions; Graph ANDs every predicate")
        }
        // Outlook numbers rules from 1. Sending 0 is rejected at request time
        // with: MessageRuleValidationError ... Field: 'Sequence', Value: '0'.
        if let order = rule.order, order < 1 {
            reject("an evaluation order of \(order); Outlook numbers rules from 1")
        }

        let conditions = encodePredicates(rule.conditions, as: "condition", reject: reject)
        let exceptions = encodePredicates(rule.exceptions, as: "exception", reject: reject)
        let actions = encodeActions(rule.actions, reject: reject)

        guard issues.isEmpty else { throw MappingError.unsupported(issues) }

        return MessageRule(
            id: rule.id,
            displayName: rule.name,
            // nil leaves a rule where it is on update; GraphRuleStore appends
            // on create.
            sequence: rule.order,
            isEnabled: rule.isEnabled,
            // Always present, even when empty: on PATCH Graph replaces the
            // whole object, `{}` clears it, and an absent key keeps the old
            // value, which is how removed exceptions used to survive a save.
            conditions: conditions,
            exceptions: exceptions,
            actions: actions
        )
    }

    private func encodePredicates(
        _ conditions: [RuleCondition], as label: String, reject: (String, String?) -> Void
    ) -> MessageRulePredicates {
        var predicates = MessageRulePredicates()
        var used: Set<String> = []

        /// Graph has one slot per predicate. Two conditions on it would mean
        /// AND in the neutral model, and the second would silently replace
        /// the first.
        func claim(_ field: String, _ condition: RuleCondition) -> Bool {
            if used.insert(field).inserted { return true }
            reject("two \(label)s that both test \(field)",
                   "Put every value in one \(label); Outlook matches any of them.")
            return false
        }

        /// Graph stores a false test as no test at all, so "has no attachment"
        /// would quietly become "every message" (`predicates-negated.json`).
        func refuseNegated(_ negative: String, positive: String) {
            reject("a \(label) for \u{201C}\(negative)\u{201D}. Outlook ignores a test set to false, so the rule would apply to every message",
                   label == "condition"
                       ? "Add \u{201C}\(positive)\u{201D} as an exception instead; that means the same thing."
                       : "Add \u{201C}\(positive)\u{201D} as a condition instead; that means the same thing.")
        }

        for condition in conditions {
            switch condition {
            case .from(let match):
                switch match.mode {
                case .contains:
                    if claim("senderContains", condition) { predicates.senderContains = match.anyOf }
                case .equals:
                    if claim("fromAddresses", condition) { predicates.fromAddresses = match.anyOf.map { Recipient(address: $0) } }
                default: reject("a \(match.mode.rawValue) match on the sender", nil)
                }

            case .recipient(let match):
                switch match.mode {
                case .contains:
                    if claim("recipientContains", condition) { predicates.recipientContains = match.anyOf }
                case .equals:
                    if claim("sentToAddresses", condition) { predicates.sentToAddresses = match.anyOf.map { Recipient(address: $0) } }
                default: reject("a \(match.mode.rawValue) match on recipients", nil)
                }

            case .subject(let match):
                guard match.mode == .contains else { reject("a \(match.mode.rawValue) match on the subject", nil); continue }
                if claim("subjectContains", condition) { predicates.subjectContains = match.anyOf }

            case .body(let match):
                guard match.mode == .contains else { reject("a \(match.mode.rawValue) match on the body", nil); continue }
                if claim("bodyContains", condition) { predicates.bodyContains = match.anyOf }

            case .subjectOrBody(let match):
                guard match.mode == .contains else { reject("a \(match.mode.rawValue) match on subject or body", nil); continue }
                if claim("bodyOrSubjectContains", condition) { predicates.bodyOrSubjectContains = match.anyOf }

            case .header(let name, let match):
                if name != nil { reject("a test on the named header \"\(name!)\"; Graph searches all headers", nil) }
                guard match.mode == .contains else { reject("a \(match.mode.rawValue) match on headers", nil); continue }
                if claim("headerContains", condition) { predicates.headerContains = match.anyOf }

            case .hasAttachment(let value):
                guard value else { refuseNegated("has no attachment", positive: "has an attachment"); continue }
                if claim("hasAttachments", condition) { predicates.hasAttachments = true }

            case .size(let size):
                guard claim("withinSizeRange", condition) else { continue }
                // Graph is in kilobytes. Round outward so the converted range
                // never excludes a message the neutral range included.
                let low = size.minimumBytes.map { max(0, $0) / 1024 }
                let high = size.maximumBytes.map { bytes in
                    max(0, bytes) / 1024 + (max(0, bytes) % 1024 == 0 ? 0 : 1)
                }
                if let low, low > Self.largestSizeKB {
                    reject("a minimum size over 2 GB", nil)
                    continue
                }
                predicates.withinSizeRange = SizeRange(
                    minimumSize: low,
                    // An absent maximum is read as 0, which makes "at least N"
                    // a 400 (`size-bounds.json`).
                    maximumSize: min(high ?? Self.largestSizeKB, Self.largestSizeKB)
                )

            case .importance(let value):
                if claim("importance", condition) { predicates.importance = value }
            case .sensitivity(let value):
                if claim("sensitivity", condition) { predicates.sensitivity = value }
            case .hasLabels(let values):
                if claim("categories", condition) { predicates.categories = values }
            case .actionFlag(let value):
                if claim("messageActionFlag", condition) { predicates.messageActionFlag = value }

            case .addressed(let scope):
                switch scope {
                case .toMe: if claim("sentToMe", condition) { predicates.sentToMe = true }
                case .ccMe: if claim("sentCcMe", condition) { predicates.sentCcMe = true }
                case .toOrCcMe: if claim("sentToOrCcMe", condition) { predicates.sentToOrCcMe = true }
                case .onlyToMe: if claim("sentOnlyToMe", condition) { predicates.sentOnlyToMe = true }
                case .notToMe: if claim("notSentToMe", condition) { predicates.notSentToMe = true }
                }

            case .messageKind(let kind, let expected):
                guard kind != .chat else { reject("a test for chat messages", nil); continue }
                guard expected else { refuseNegated("is not \(Self.phrase(kind))", positive: "is \(Self.phrase(kind))"); continue }
                let field = Self.messageKindField[kind]!
                guard claim(field, condition) else { continue }
                switch kind {
                case .meetingRequest: predicates.isMeetingRequest = true
                case .meetingResponse: predicates.isMeetingResponse = true
                case .readReceipt: predicates.isReadReceipt = true
                case .nonDeliveryReport: predicates.isNonDeliveryReport = true
                case .automaticReply: predicates.isAutomaticReply = true
                case .automaticForward: predicates.isAutomaticForward = true
                case .voicemail: predicates.isVoicemail = true
                case .approvalRequest: predicates.isApprovalRequest = true
                case .encrypted: predicates.isEncrypted = true
                case .signed: predicates.isSigned = true
                case .permissionControlled: predicates.isPermissionControlled = true
                case .chat: break
                }

            case .rawQuery(let provider, _):
                reject("a raw \(provider.rawValue) query; Graph rules have no query syntax", nil)
            }
        }

        return predicates
    }

    /// "a meeting request", "encrypted": what follows "a message is".
    static func phrase(_ kind: MessageKind) -> String {
        switch kind {
        case .encrypted, .signed, .permissionControlled: kind.rawValue.outlookMessageType.lowercased()
        case .automaticReply, .automaticForward, .approvalRequest:
            "an " + kind.rawValue.outlookMessageType.lowercased()
        default: "a " + kind.rawValue.outlookMessageType.lowercased()
        }
    }

    private static let messageKindField: [MessageKind: String] = [
        .meetingRequest: "isMeetingRequest", .meetingResponse: "isMeetingResponse",
        .readReceipt: "isReadReceipt", .nonDeliveryReport: "isNonDeliveryReport",
        .automaticReply: "isAutomaticReply", .automaticForward: "isAutomaticForward",
        .voicemail: "isVoicemail", .approvalRequest: "isApprovalRequest",
        .encrypted: "isEncrypted", .signed: "isSigned",
        .permissionControlled: "isPermissionControlled",
    ]

    private func encodeActions(
        _ actions: [RuleAction], reject: (String, String?) -> Void
    ) -> MessageRuleActions? {
        guard !actions.isEmpty else { return nil }
        var encoded = MessageRuleActions()
        var categories: [String] = []
        var used: Set<ActionKind> = []

        /// Graph has one slot per action, so a second one would silently win.
        func claim(_ action: RuleAction) -> Bool {
            if used.insert(action.kind).inserted { return true }
            reject("two \u{201C}\(action.kind.rawValue)\u{201D} actions in one rule",
                   "Keep one, or split the rule in two.")
            return false
        }

        /// Graph refuses a display name: "Id is malformed." The store looks
        /// ids up before encoding; reaching here without one means it could
        /// not, or no folder was chosen.
        func folderID(_ folder: MailboxFolder) -> String? {
            if let id = folder.id, !id.isEmpty { return id }
            if let name = folder.name, !name.isEmpty {
                reject("a move to \u{201C}\(name)\u{201D}, which isn't a folder in this mailbox",
                       "Choose the folder from the list.")
            } else {
                reject("a move or copy with no folder chosen", "Choose a folder.")
            }
            return nil
        }

        for action in actions {
            switch action {
            case .moveTo(let folder):
                if claim(action), let id = folderID(folder) { encoded.moveToFolder = id }
            case .copyTo(let folder):
                if claim(action), let id = folderID(folder) { encoded.copyToFolder = id }
            // Outlook categories are the closest thing it has to labels.
            case .addLabel(let folder): categories.append(folder.name ?? folder.id ?? "")
            case .markAsRead(let value):
                // Graph stores false as nothing, and then has no action at all.
                guard value else { reject("leaving a message unread as an action", "Remove that action."); continue }
                if claim(action) { encoded.markAsRead = true }
            case .markImportance(let value):
                if claim(action) { encoded.markImportance = value }
            case .forward(let to):
                if claim(action) { encoded.forwardTo = to.map(Recipient.init(mail:)) }
            case .forwardAsAttachment(let to):
                if claim(action) { encoded.forwardAsAttachmentTo = to.map(Recipient.init(mail:)) }
            case .redirect(let to):
                if claim(action) { encoded.redirectTo = to.map(Recipient.init(mail:)) }
            case .delete(let permanent):
                guard claim(action) else { continue }
                if permanent { encoded.permanentDelete = true } else { encoded.delete = true }
                // Graph adds this to every delete whatever is sent; sending it
                // keeps what is written equal to what is stored.
                encoded.stopProcessingRules = true
            case .stopProcessing: encoded.stopProcessingRules = true
            case .removeLabel: reject("removing a category", nil)
            case .markAsStarred: reject("starring a message", nil)
            case .archive: reject("archiving; move the message to a folder instead", nil)
            case .markAsSpam: reject("a junk-mail action in a rule", nil)
            }
        }

        if !categories.isEmpty { encoded.assignCategories = categories }
        return encoded
    }

    // MARK: - Graph -> Neutral

    public func decode(_ native: MessageRule) throws -> MailRule {
        MailRule(
            id: native.id,
            name: native.displayName,
            order: native.sequence,
            isEnabled: native.isEnabled ?? true,
            match: .all,
            conditions: decodePredicates(native.conditions),
            exceptions: decodePredicates(native.exceptions),
            actions: decodeActions(native.actions),
            status: RuleStatus(
                hasError: native.hasError ?? false,
                isReadOnly: native.isReadOnly ?? false
            )
        )
    }

    private func decodePredicates(_ predicates: MessageRulePredicates?) -> [RuleCondition] {
        guard let p = predicates else { return [] }
        var conditions: [RuleCondition] = []

        // Graph upper-cases these two on storage, and matches them without
        // regard to case, so lower case says the same thing more readably.
        if let v = p.senderContains { conditions.append(.from(StringMatch(v.map { $0.lowercased() }))) }
        if let v = p.fromAddresses {
            conditions.append(.from(StringMatch(v.compactMap(\.emailAddress.address), mode: .equals)))
        }
        if let v = p.recipientContains { conditions.append(.recipient(StringMatch(v.map { $0.lowercased() }))) }
        if let v = p.sentToAddresses {
            conditions.append(.recipient(StringMatch(v.compactMap(\.emailAddress.address), mode: .equals)))
        }
        if let v = p.subjectContains { conditions.append(.subject(StringMatch(v))) }
        if let v = p.bodyContains { conditions.append(.body(StringMatch(v))) }
        if let v = p.bodyOrSubjectContains { conditions.append(.subjectOrBody(StringMatch(v))) }
        if let v = p.headerContains { conditions.append(.header(name: nil, match: StringMatch(v))) }
        if p.hasAttachments == true { conditions.append(.hasAttachment(true)) }
        if let v = p.withinSizeRange {
            // Graph fills an absent bound with 0, and "at least N" is written
            // as N…2 GB; undo both so the rule reads back as it was made.
            let low = (v.minimumSize ?? 0) > 0 ? v.minimumSize : nil
            let high = (v.maximumSize ?? 0) >= Self.largestSizeKB ? nil : v.maximumSize
            conditions.append(.size(SizeConstraint(
                minimumBytes: low.map { $0 * 1024 },
                maximumBytes: high.map { $0 * 1024 }
            )))
        }
        if let v = p.importance { conditions.append(.importance(v)) }
        if let v = p.sensitivity { conditions.append(.sensitivity(v)) }
        if let v = p.categories { conditions.append(.hasLabels(v)) }
        if let v = p.messageActionFlag { conditions.append(.actionFlag(v)) }

        // Graph never stores `false` (`predicates-negated.json`), so only the
        // true side can arrive.
        if p.sentToMe == true { conditions.append(.addressed(.toMe)) }
        if p.sentCcMe == true { conditions.append(.addressed(.ccMe)) }
        if p.sentToOrCcMe == true { conditions.append(.addressed(.toOrCcMe)) }
        if p.sentOnlyToMe == true { conditions.append(.addressed(.onlyToMe)) }
        if p.notSentToMe == true { conditions.append(.addressed(.notToMe)) }

        let kinds: [(Bool?, MessageKind)] = [
            (p.isMeetingRequest, .meetingRequest),
            (p.isMeetingResponse, .meetingResponse),
            (p.isReadReceipt, .readReceipt),
            (p.isNonDeliveryReport, .nonDeliveryReport),
            (p.isAutomaticReply, .automaticReply),
            (p.isAutomaticForward, .automaticForward),
            (p.isVoicemail, .voicemail),
            (p.isApprovalRequest, .approvalRequest),
            (p.isEncrypted, .encrypted),
            (p.isSigned, .signed),
            (p.isPermissionControlled, .permissionControlled),
        ]
        for (value, kind) in kinds where value == true {
            conditions.append(.messageKind(kind, true))
        }

        return conditions
    }

    private func decodeActions(_ actions: MessageRuleActions?) -> [RuleAction] {
        guard let a = actions else { return [] }
        var decoded: [RuleAction] = []

        if let v = a.moveToFolder { decoded.append(.moveTo(.id(v))) }
        if let v = a.copyToFolder { decoded.append(.copyTo(.id(v))) }
        if let v = a.assignCategories { decoded.append(contentsOf: v.map { .addLabel(.named($0)) }) }
        if a.markAsRead == true { decoded.append(.markAsRead(true)) }
        if let v = a.markImportance { decoded.append(.markImportance(v)) }
        if let v = a.forwardTo { decoded.append(.forward(v.map(\.mail))) }
        if let v = a.forwardAsAttachmentTo { decoded.append(.forwardAsAttachment(v.map(\.mail))) }
        if let v = a.redirectTo { decoded.append(.redirect(v.map(\.mail))) }
        if a.permanentDelete == true { decoded.append(.delete(permanent: true)) }
        else if a.delete == true { decoded.append(.delete(permanent: false)) }
        if a.stopProcessingRules == true { decoded.append(.stopProcessing) }

        return decoded
    }
}

// MARK: - Address bridging

extension Recipient {
    init(mail: MailAddress) {
        self.init(emailAddress: EmailAddress(name: mail.name, address: mail.address))
    }

    /// Graph fills a missing display name with the address itself; reading
    /// that back as "no name" keeps the rule equal to what was written.
    var mail: MailAddress {
        let address = emailAddress.address ?? ""
        let name = emailAddress.name.flatMap { $0.caseInsensitiveCompare(address) == .orderedSame ? nil : $0 }
        return MailAddress(address, name: name)
    }
}
