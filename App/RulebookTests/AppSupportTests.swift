import Foundation
import Testing
import RulebookKit
@testable import Rulebook

@MainActor
@Suite("Accounts")
struct AccountStoreTests {

    func defaults() -> UserDefaults { UserDefaults(suiteName: "rulebook-test-\(UUID().uuidString)")! }

    @Test("Accounts and the active one survive a relaunch")
    func persists() {
        let defaults = defaults()
        let store = AccountStore(defaults: defaults)
        store.add(Account(id: "a", address: "a@example.com", displayName: "A"))
        store.add(Account(id: "b", address: "b@example.com", displayName: "B"))
        store.activate(store.accounts[0])

        let reopened = AccountStore(defaults: defaults)
        #expect(reopened.accounts.map(\.id) == ["a", "b"])
        #expect(reopened.active?.id == "a")
    }

    @Test("Removing the active account falls back to another")
    func removeActive() {
        let store = AccountStore(defaults: defaults())
        store.add(Account(id: "a", address: "a@example.com", displayName: "A"))
        store.add(Account(id: "b", address: "b@example.com", displayName: "B"))
        store.remove(store.active!)
        #expect(store.active?.id == "a")
        store.remove(store.active!)
        #expect(store.active == nil)
        #expect(store.isEmpty)
    }

    @Test("Adding an account that's already there replaces it rather than duplicating")
    func reAdd() {
        let store = AccountStore(defaults: defaults())
        store.add(Account(id: "a", address: "a@example.com", displayName: "A"))
        store.add(Account(id: "a", address: "a@example.com", displayName: "A again"))
        #expect(store.accounts.count == 1)
    }

    @Test("A stored active id that no longer exists falls back to the first account")
    func staleActive() {
        let defaults = defaults()
        let store = AccountStore(defaults: defaults)
        store.add(Account(id: "a", address: "a@example.com", displayName: "A"))
        defaults.set("gone", forKey: "rulebook.accounts.active.nonexistent")
        store.activeID = "gone"
        #expect(store.active?.id == "a")
    }

    @Test("Corrupt saved data starts empty instead of crashing")
    func corrupt() {
        let defaults = defaults()
        defaults.set(Data("not json".utf8), forKey: "rulebook.accounts")
        #expect(AccountStore(defaults: defaults).isEmpty)
    }

    @Test("Display names read like names", arguments: [
        ("d.okonjo@company.com", "D Okonjo — Outlook"),
        ("dana_okonjo@company.com", "Dana Okonjo — Outlook"),
        ("dana@company.com", "Dana — Outlook"),
        ("noatsign", "Noatsign — Outlook"),
    ])
    func displayName(_ address: String, _ expected: String) {
        #expect(Account.displayName(for: address) == expected)
    }
}

@Suite("Diagnostics log")
struct DiagnosticsLogTests {

    @Test("Addresses never reach the shareable log")
    func redactsAddresses() {
        let line = DiagnosticsLog.redacted("AADSTS50020: User account 'dana.okonjo@contoso.com' from identity provider")
        #expect(!line.contains("@"))
        #expect(line.contains("<address>"))
        #expect(line.contains("AADSTS50020"))
    }
}

@MainActor
@Suite("Pro")
struct ProStoreTests {

    @Test("A launch starts from the last known entitlement, so a paid user isn't shown locks")
    func startsFromLastKnown() {
        let defaults = UserDefaults(suiteName: "rulebook-pro-\(UUID().uuidString)")!
        #expect(!ProStore(defaults: defaults).isPro)
        defaults.set(true, forKey: "rulebook.pro.lastKnown")
        #expect(ProStore(defaults: defaults).isPro)
    }

    @Test("The demo build is unlocked without StoreKit")
    func alwaysUnlocked() {
        #expect(ProStore(alwaysUnlocked: true).isPro)
    }
}
