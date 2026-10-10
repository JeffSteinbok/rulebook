import Foundation
import Testing
@testable import RulebookKit

@Suite("Neutral model")
struct NeutralModelTests {

    @Test("The fixture rule set decodes into the neutral model")
    func decodesNeutralRules() throws {
        let rules = try Fixtures.decode([MailRule].self, from: "neutral-rules")
        #expect(rules.count == 2)

        let first = try #require(rules.first)
        #expect(first.name == "Newsletters to Reading")
        #expect(first.order == 1)
        #expect(first.match == .all)
        #expect(first.conditions.count == 2)
        #expect(first.exceptions.count == 1)
        #expect(first.action(.moveTo) == .moveTo(MailboxFolder(id: "folder-reading", name: "Reading")))
        #expect(first.actions.contains(.stopProcessing))
    }

    @Test("Conditions survive a JSON round trip", arguments: [
        RuleCondition.from(StringMatch(["a", "b"], mode: .equals)),
        .subject(StringMatch("hello")),
        .header(name: "X-Mailer", match: StringMatch("thing")),
        .hasAttachment(false),
        .size(SizeConstraint(minimumBytes: 1024, maximumBytes: 4096)),
        .importance(.high),
        .sensitivity(.private),
        .hasLabels(["Reading", "Bulky"]),
        .addressed(.onlyToMe),
        .messageKind(.meetingRequest, false),
        .actionFlag(.followUp),
        .rawQuery(provider: .microsoft, query: "size>5MB"),
    ])
    func conditionsRoundTrip(condition: RuleCondition) throws {
        #expect(try jsonRoundTrip(condition) == condition)
    }

    @Test("Actions survive a JSON round trip", arguments: [
        RuleAction.moveTo(.id("folder-1")),
        .copyTo(.named("Archive")),
        .addLabel(.named("Reading")),
        .removeLabel(.id("Label_1")),
        .markAsRead(false),
        .markAsStarred(true),
        .markImportance(.low),
        .forward([MailAddress("a@b.com", name: "A")]),
        .forwardAsAttachment([MailAddress("a@b.com")]),
        .redirect([MailAddress("a@b.com")]),
        .delete(permanent: true),
        .archive,
        .markAsSpam(false),
        .stopProcessing,
    ])
    func actionsRoundTrip(action: RuleAction) throws {
        #expect(try jsonRoundTrip(action) == action)
    }

    @Test("Conditions encode as a readable discriminated union, not Swift's _0 shape")
    func conditionWireFormat() throws {
        let data = try JSONEncoder().encode(RuleCondition.subject(StringMatch("weekly")))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["kind"] as? String == "subject")
        #expect(object["match"] != nil)
        #expect(object["_0"] == nil)
    }

    @Test("Toggle actions default to true when the value is omitted")
    func toggleDefaults() throws {
        let json = Data(#"{"kind":"markAsRead"}"#.utf8)
        #expect(try JSONDecoder().decode(RuleAction.self, from: json) == .markAsRead(true))
    }

    @Test("The write payload drops provider-owned state")
    func writablePayloadStripsProviderState() {
        var rule = MailRule.stub()
        rule.id = "abc"
        rule.status = RuleStatus(hasError: true, isReadOnly: true)

        let payload = rule.writablePayload()
        #expect(payload.id == nil)
        #expect(payload.status.isClean)
    }

    @Test("A hand-written rule needs only a name; the rest has defaults")
    func minimalRuleDecodes() throws {
        let rule = try JSONDecoder().decode(MailRule.self, from: Data(#"{"name":"Tiny","actions":[{"kind":"markAsRead"}]}"#.utf8))
        #expect(rule.name == "Tiny")
        #expect(rule.isEnabled)
        #expect(rule.match == .all)
        #expect(rule.conditions.isEmpty)
        #expect(rule.actions == [.markAsRead(true)])
    }
}
