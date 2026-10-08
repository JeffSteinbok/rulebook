import Foundation
import Testing
@testable import RulebookKit

@Suite("Outlook / Graph mapper")
struct GraphMapperTests {
    let mapper = GraphRuleMapper()

    @Test("A neutral rule becomes the Graph shape")
    func encodesToGraph() throws {
        let rules = try Fixtures.decode([MailRule].self, from: "neutral-rules")
        let native = try mapper.encode(rules[0])

        #expect(native.displayName == "Newsletters to Reading")
        #expect(native.sequence == 1)
        #expect(native.conditions?.senderContains == ["newsletter", "digest"])
        #expect(native.conditions?.subjectContains == ["weekly"])
        // `.equals` on an address maps to fromAddresses, not senderContains.
        #expect(native.exceptions?.fromAddresses?.first?.emailAddress.address == "owner@example.com")
        // Graph takes a folder id, never a display name ("Id is malformed.").
        #expect(native.actions?.moveToFolder == "folder-reading")
        #expect(native.actions?.markAsRead == true)
        #expect(native.actions?.stopProcessingRules == true)
    }

    @Test("addLabel becomes an Outlook category")
    func labelsBecomeCategories() throws {
        let rules = try Fixtures.decode([MailRule].self, from: "neutral-rules")
        let native = try mapper.encode(rules[1])
        #expect(native.actions?.assignCategories == ["Bulky"])
        #expect(native.actions?.markImportance == .low)
    }

    @Test("Sizes convert from bytes to Graph's kilobytes, rounding outward")
    func sizeUnitsConvert() throws {
        let rule = MailRule.stub(conditions: [.size(SizeConstraint(minimumBytes: 5000, maximumBytes: 5000))])
        let range = try #require(try mapper.encode(rule).conditions?.withinSizeRange)

        // 5000 B is 4.88 KB: the floor for the minimum, the ceiling for the
        // maximum, so the converted range never excludes a matching message.
        #expect(range.minimumSize == 4)
        #expect(range.maximumSize == 5)
    }

    @Test("Graph rules decode back into the neutral model")
    func decodesFromGraph() throws {
        let native = try Fixtures.decode(MessageRule.self, from: "newsletter-rule")
        let rule = try mapper.decode(native)

        #expect(rule.name == "Newsletters to Reading")
        #expect(rule.order == 1)
        #expect(rule.conditions.contains(.from(StringMatch(["newsletter", "digest"]))))
        #expect(rule.conditions.contains(.importance(.low)))
        #expect(rule.actions.contains(.markAsRead(true)))
        #expect(rule.actions.contains(.addLabel(.named("Reading"))))
        #expect(rule.status.isClean)
    }

    @Test("Neutral -> Graph -> neutral preserves what Outlook can hold")
    func roundTrips() throws {
        let original = MailRule(
            name: "Round trip",
            order: 4,
            conditions: [
                .from(StringMatch(["a@b.com"], mode: .equals)),
                .subject(StringMatch(["hello", "there"])),
                .hasAttachment(true),
                .importance(.high),
                .addressed(.toOrCcMe),
                .messageKind(.meetingRequest, true),
            ],
            actions: [.moveTo(.id("folder-1")), .markAsRead(true), .stopProcessing]
        )

        let back = try mapper.decode(try mapper.encode(original))

        #expect(back.name == original.name)
        #expect(back.order == original.order)
        #expect(Set(back.conditions) == Set(original.conditions))
        #expect(Set(back.actions) == Set(original.actions))
    }

    @Test("What Outlook cannot do is reported, not dropped")
    func reportsUnsupported() throws {
        let rule = MailRule.stub(actions: [.archive, .markAsStarred(true), .markAsSpam(true)])

        do {
            _ = try mapper.encode(rule)
            Issue.record("Expected the mapper to refuse.")
        } catch let MappingError.unsupported(issues) {
            let text = issues.map(\.message).joined(separator: "\n")
            #expect(issues.count == 3)
            #expect(text.contains("archiving"))
            #expect(text.contains("starring"))
            #expect(text.contains("junk"))
        }
    }

    @Test("An exact-match subject is refused; Graph only does contains")
    func exactSubjectIsRefused() throws {
        let rule = MailRule.stub(conditions: [.subject(StringMatch("exact", mode: .equals))])

        do {
            _ = try mapper.encode(rule)
            Issue.record("Expected the mapper to refuse.")
        } catch let MappingError.unsupported(issues) {
            #expect(issues.first?.message.contains("equals match on the subject") == true)
        }
    }
}

@Suite("Capability checks")
struct CapabilityCheckTests {

    @Test("A refusal names the provider that cannot do it")
    func capabilityCheckExplains() {
        // markAsStarred has no Graph equivalent; the check has to say so
        // locally, before any request is made.
        let unsupported = MailRule.stub(actions: [.markAsStarred(true)])
        let issues = RuleCompatibility.check(unsupported, against: GraphRuleMapper.capabilities)

        #expect(issues.hasErrors)
        #expect(issues.first?.message.contains("microsoft does not support") == true)
    }

    @Test("A rule Graph can express passes cleanly")
    func supportedRulePasses() throws {
        let rule = MailRule(
            name: "Newsletters",
            order: 1,
            conditions: [.from(StringMatch(["newsletter"])), .hasAttachment(true)],
            actions: [.moveTo(MailboxFolder(id: "folder-reading", name: "Reading")), .markAsRead(true)]
        )

        #expect(RuleCompatibility.check(rule, against: GraphRuleMapper.capabilities).isEmpty)
        #expect(throws: Never.self) { try GraphRuleMapper().encode(rule) }
    }

    @Test("The unrestricted profile refuses nothing")
    func unrestrictedAcceptsEverything() {
        let rule = MailRule.stub(actions: [.markAsStarred(true), .stopProcessing])
        #expect(RuleCompatibility.check(rule, against: .unrestricted).isEmpty)
    }
}

@Suite("Outlook evaluation order")
struct GraphOrderTests {
    let mapper = GraphRuleMapper()

    @Test("A rule with no stated order sends no sequence, so an update leaves it in place")
    func omitsAbsentOrder() throws {
        // On PATCH an absent sequence keeps the rule's position. On create,
        // GraphRuleStore appends instead (Graph refuses a POST without one).
        #expect(try mapper.encode(MailRule.stub(order: nil)).sequence == nil)
    }

    @Test("An explicit order of 0 is refused, with the reason")
    func refusesZero() throws {
        do {
            _ = try mapper.encode(MailRule.stub(order: 0))
            Issue.record("Expected the mapper to refuse sequence 0.")
        } catch let MappingError.unsupported(issues) {
            #expect(issues.contains { $0.message.contains("numbers rules from 1") })
        }
    }

    @Test("A real order passes through untouched")
    func keepsRealOrder() throws {
        #expect(try mapper.encode(MailRule.stub(order: 7)).sequence == 7)
    }
}
