import RulebookKit

/// One of everything Outlook can store, for suites that check a rule means
/// the same thing after the round trip: against ``FakeGraph`` in the
/// hermetic suite, and against a real mailbox in the live one.
public enum RuleSamples {

    /// Every condition Outlook can hold, each in its own rule.
    public static let conditions: [RuleCondition] = [
        .from(StringMatch(["news@example.com", "digest"])),
        .from(StringMatch(["boss@example.com"], mode: .equals)),
        .recipient(StringMatch(["team"])),
        .recipient(StringMatch(["list@example.com"], mode: .equals)),
        .subject(StringMatch(["Invoice", "Receipt"])),
        .body(StringMatch(["unsubscribe"])),
        .subjectOrBody(StringMatch(["urgent"])),
        .header(name: nil, match: StringMatch(["X-Mailer"])),
        .hasAttachment(true),
        .size(SizeConstraint(minimumBytes: 10 * 1024, maximumBytes: 200 * 1024)),
        .size(SizeConstraint(minimumBytes: 5 * 1_048_576)),
        .size(SizeConstraint(maximumBytes: 50 * 1024)),
        .importance(.high),
        .sensitivity(.confidential),
        .hasLabels(["Red category"]),
        .actionFlag(.followUp),
    ] + AddressedScope.allCases.map { .addressed($0) }
      + MessageKind.allCases.filter { $0 != .chat }.map { .messageKind($0, true) }

    /// Action sets that don't name a folder, so any mailbox can take them.
    public static let folderlessActions: [[RuleAction]] = [
        [.addLabel(.named("Red category"))],
        [.addLabel(.named("Red category")), .addLabel(.named("Blue category"))],
        [.markAsRead(true)],
        [.markImportance(.low)],
        [.forward([MailAddress("assistant@example.com", name: "Assistant")])],
        [.forwardAsAttachment([MailAddress("archive@example.com")])],
        [.redirect([MailAddress("other@example.com")])],
        [.delete(permanent: false), .stopProcessing],
        [.delete(permanent: true), .stopProcessing],
        [.markAsRead(true), .stopProcessing],
        [.stopProcessing],
    ]

    /// Conditions Outlook would silently store as nothing. Each must be
    /// refused before it is sent.
    public static let negated: [RuleCondition] = [
        .hasAttachment(false),
    ] + MessageKind.allCases.filter { $0 != .chat }.map { .messageKind($0, false) }
}
