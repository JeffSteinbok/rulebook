import Foundation

/// An in-process ``RuleStore`` for tests, previews, and offline CLI runs.
///
/// Reproduces the behaviour call sites depend on: provider-assigned ids,
/// merge-on-update, and rules coming back in evaluation order.
public actor InMemoryRuleStore: RuleStore {
    public nonisolated let capabilities: RuleCapabilities

    private var storage: [String: MailRule] = [:]
    private var nextID: Int = 1

    public init(seed: [MailRule] = [], capabilities: RuleCapabilities = .unrestricted) {
        self.capabilities = capabilities
        for rule in seed {
            var stored = rule
            if stored.id == nil {
                stored.id = "rule-\(nextID)"
                nextID += 1
            }
            storage[stored.id!] = stored
        }
    }

    /// Never reuses an id a seed rule already has: seeds read back from a
    /// file carry `rule-1`, `rule-2`…, and colliding with one would overwrite it.
    private func makeID() -> String {
        while storage["rule-\(nextID)"] != nil { nextID += 1 }
        defer { nextID += 1 }
        return "rule-\(nextID)"
    }

    public func listRules() async throws -> [MailRule] {
        storage.values.sorted { ($0.order ?? .max, $0.name) < ($1.order ?? .max, $1.name) }
    }

    public func rule(id: String) async throws -> MailRule {
        guard let rule = storage[id] else { throw RuleStoreError.notFound(id: id) }
        return rule
    }

    public func createRule(_ rule: MailRule) async throws -> MailRule {
        var created = rule.writablePayload()
        created.id = makeID()
        if created.order == nil {
            created.order = (storage.values.compactMap(\.order).max() ?? 0) + 1
        }
        storage[created.id!] = created
        return created
    }

    /// Replaces everything but the id and status; a `nil` order keeps the
    /// stored one.
    public func updateRule(id: String, with rule: MailRule) async throws -> MailRule {
        guard let existing = storage[id] else { throw RuleStoreError.notFound(id: id) }
        var updated = rule.writablePayload()
        updated.id = id
        updated.status = existing.status
        if updated.order == nil { updated.order = existing.order }
        storage[id] = updated
        return updated
    }

    /// Renumbers every rule 1…N with this one at `position`, which is what
    /// Outlook does.
    public func moveRule(id: String, toPosition position: Int) async throws {
        guard storage[id] != nil else { throw RuleStoreError.notFound(id: id) }
        var ordered = try await listRules().map { $0.id! }
        ordered.removeAll { $0 == id }
        ordered.insert(id, at: max(0, min(position - 1, ordered.count)))
        for (index, ruleID) in ordered.enumerated() {
            storage[ruleID]?.order = index + 1
        }
    }

    public func deleteRule(id: String) async throws {
        guard storage.removeValue(forKey: id) != nil else {
            throw RuleStoreError.notFound(id: id)
        }
    }
}
