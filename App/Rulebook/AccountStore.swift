import Foundation
import Observation
import RulebookKit

/// One connected mailbox.
///
/// `RulebookKit` has one store per account and no notion of a set, so the
/// multi-mailbox model lives app-side. Only the address and display name are
/// persisted — tokens stay in MSAL's Keychain-backed cache.
struct Account: Identifiable, Codable, Hashable {
    var id: String            // MSAL homeAccountId
    var address: String
    var displayName: String

    /// "Dana Okonjo · Outlook" from "d.okonjo@company.com".
    static func displayName(for address: String, provider: String = "Outlook") -> String {
        let local = address.split(separator: "@").first.map(String.init) ?? address
        let words = local
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
        return "\(words) · \(provider)"
    }
}

@MainActor
@Observable
final class AccountStore {

    private(set) var accounts: [Account] = []
    var activeID: String?

    private let defaults: UserDefaults
    private let key = "rulebook.accounts"
    private let activeKey = "rulebook.activeAccount"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    var active: Account? {
        accounts.first { $0.id == activeID } ?? accounts.first
    }

    var isEmpty: Bool { accounts.isEmpty }

    func add(_ account: Account) {
        accounts.removeAll { $0.id == account.id }
        accounts.append(account)
        activeID = account.id
        persist()
    }

    func remove(_ account: Account) {
        accounts.removeAll { $0.id == account.id }
        if activeID == account.id { activeID = accounts.first?.id }
        persist()
    }

    func activate(_ account: Account) {
        activeID = account.id
        persist()
    }

    private func load() {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Account].self, from: data)
        else { return }
        accounts = decoded
        activeID = defaults.string(forKey: activeKey) ?? decoded.first?.id
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(accounts) {
            defaults.set(data, forKey: key)
        }
        defaults.set(activeID, forKey: activeKey)
    }
}
