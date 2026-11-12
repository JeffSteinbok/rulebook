import Foundation
import RulebookKit

/// Shared fixtures for previews and simulator runs with no account.
///
/// Deliberately includes broken and admin-managed rules: those states are the
/// hardest to reach by hand and the easiest to ship broken.
enum PreviewSeed {

    static let folders = StaticFolderDirectory([
        "f1": "Finance/Invoices",
        "f2": "Later",
        "f3": "Reading",
        "f4": "Company",
    ])

    static let rules: [MailRule] = [
        MailRule(
            id: "rule-1", name: "Vendor invoices → Finance", order: 0,
            conditions: [
                .recipient(.init("accounts@")),
                .subject(.init("invoice")),
            ],
            actions: [.moveTo(.named("Finance/Invoices")), .markAsRead(true)]
        ),
        MailRule(
            id: "rule-2", name: "All-staff announcements", order: 1,
            match: .any,
            conditions: [
                .from(.init("comms@company.com", mode: .equals)),
                .subject(.init("[All Staff]", mode: .startsWith)),
            ],
            actions: [.moveTo(.named("Company"))]
        ),
        MailRule(
            // Files into a folder the directory doesn't contain — the
            // missing-folder diagnostic should catch this one.
            id: "rule-3", name: "Print room + facilities", order: 2,
            match: .any,
            conditions: [.from(.init("facilities@")), .from(.init("printroom@"))],
            actions: [.moveTo(.named("Building"))]
        ),
        MailRule(
            id: "rule-4", name: "Recruiter cold mail", order: 3,
            isEnabled: false, match: .any,
            conditions: [.subject(.init("opportunity")), .body(.init("your profile"))],
            actions: [.moveTo(.named("Later"))]
        ),
        MailRule(
            id: "rule-5", name: "Newsletters out of the inbox", order: 4,
            match: .any,
            conditions: [.body(.init("unsubscribe")), .from(.init("newsletter@"))],
            exceptions: [.from(.init("@company.com"))],
            actions: [.moveTo(.named("Reading")), .markAsRead(true)],
            // Exercises the hasError path.
            status: .init(hasError: true)
        ),
        MailRule(
            id: "rule-6", name: "Anything from my manager", order: 5,
            conditions: [.from(.init("d.okonjo@company.com", mode: .equals))],
            actions: [.markImportance(.high), .stopProcessing],
            // Admin-owned: no swipe action, dimmed toggle, skipped by bulk ops.
            status: .init(isReadOnly: true)
        ),
        MailRule(
            // Sits after an unconditional stopProcessing, so the
            // "never runs" warning should fire.
            id: "rule-7", name: "Weekly report reminders", order: 6,
            conditions: [.subject(.init("weekly report"))],
            actions: [.markAsRead(true)]
        ),
    ]

    static func store() -> InMemoryRuleStore {
        InMemoryRuleStore(seed: rules, capabilities: GraphRuleMapper.capabilities)
    }

    /// The demo mailbox's rules. One store rather than one per switch, so edits
    /// survive switching mailboxes and back. Nothing is written to disk, so a
    /// relaunch starts from the seed again, and so does removing the mailbox.
    @MainActor static private(set) var demoStore = store()

    @MainActor static func resetDemo() { demoStore = store() }
}
