import ArgumentParser
import Foundation
import RulebookKit

@main
struct RulebookCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rulebook",
        abstract: "Inspect, validate, and edit mail rules across providers.",
        discussion: """
            Rules are held in a provider-neutral model. Each provider — Outlook
            (Microsoft 365) today — has a mapper that translates to its own
            format and declares what it can express, so an unsupported rule is
            reported here rather than rejected by the server.
            """,
        subcommands: [
            Login.self, Logout.self,
            List.self, Get.self, Describe.self,
            Create.self, Update.self, Delete.self,
            Export.self, Apply.self,
            Validate.self, Translate.self, Providers.self, Folders.self,
        ],
        defaultSubcommand: List.self
    )
}

// MARK: - Shared options

struct ProviderOption: ParsableArguments {
    @Option(
        name: .shortAndLong,
        help: "outlook (aka microsoft, m365), or local."
    )
    var provider: String?

    /// Resolved profile: the flag, else `RULEBOOK_PROVIDER`, else Outlook.
    func profile() throws -> ProviderProfile {
        let name = provider ?? ProcessInfo.processInfo.environment["RULEBOOK_PROVIDER"]
        guard let name, !name.isEmpty else { return ProviderCatalog.outlook }
        guard let profile = ProviderCatalog.profile(named: name) else {
            throw ValidationError(
                "Unknown provider \"\(name)\". Try: "
                + ProviderCatalog.all.map { $0.id.rawValue }.joined(separator: ", ")
            )
        }
        return profile
    }
}

struct StoreOptions: ParsableArguments {
    @OptionGroup var providerOption: ProviderOption

    @Option(name: .customLong("client-id"), help: "Entra ID application (client) ID.")
    var clientID: String?

    @Option(name: .customLong("tenant-id"), help: "Tenant: common, organizations, consumers, a GUID, or a domain.")
    var tenantID: String?

    @Option(
        name: .long,
        help: "Work against a local JSON file instead of a live account. No sign-in needed."
    )
    var offline: String?

    // .customLong: the derived name for `rawFolderIDs` is "--raw-folder-i-ds".
    @Flag(name: .customLong("raw-folder-ids"), help: "Show raw folder ids instead of resolving them to names.")
    var rawFolderIDs = false

    private var offlinePath: String? {
        let path = offline ?? ProcessInfo.processInfo.environment["RULEBOOK_OFFLINE"]
        return (path?.isEmpty ?? true) ? nil : path
    }

    /// The profile in play. Offline runs default to `local` — no provider
    /// limits — unless a provider was named, which makes the file behave like
    /// that provider.
    func profile() throws -> ProviderProfile {
        if offlinePath != nil && providerOption.provider == nil
            && ProcessInfo.processInfo.environment["RULEBOOK_PROVIDER"] == nil {
            return ProviderCatalog.local
        }
        return try providerOption.profile()
    }

    func store() throws -> any RuleStore {
        let profile = try profile()

        if let path = offlinePath {
            return try JSONFileRuleStore(
                url: URL(fileURLWithPath: path),
                capabilities: profile.capabilities
            )
        }

        switch profile.id {
        case .microsoft:
            return GraphRuleStore(
                tokenProvider: try tokenProvider(),
                resolveFolderNames: !rawFolderIDs
            )
        case .local:
            throw ValidationError("The local provider needs --offline <file>.")
        }
    }

    func tokenProvider() throws -> any TokenProvider {
        let environment = ProcessInfo.processInfo.environment

        // A token pasted from Graph Explorer skips the app registration entirely.
        if let token = environment["RULEBOOK_ACCESS_TOKEN"], !token.isEmpty {
            return StaticTokenProvider(token)
        }

        guard let clientID = clientID ?? environment["RULEBOOK_CLIENT_ID"], !clientID.isEmpty else {
            throw ValidationError(
                """
                No client ID. Pass --client-id, or set RULEBOOK_CLIENT_ID.
                Run Scripts/register-app.sh to create the app registration.
                """
            )
        }

        return DeviceCodeTokenProvider(
            configuration: .init(
                clientID: clientID,
                tenantID: tenantID ?? environment["RULEBOOK_TENANT_ID"] ?? "common"
            )
        )
    }
}

// MARK: - Auth

extension RulebookCLI {
    struct Login: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Sign in and cache a refresh token.")

        @OptionGroup var options: StoreOptions

        func run() async throws {
            guard let provider = try options.tokenProvider() as? DeviceCodeTokenProvider else {
                print("RULEBOOK_ACCESS_TOKEN is set; nothing to sign in to.")
                return
            }
            try await provider.signIn()
            print("Signed in. Token cached at ~/.rulebook/token.json")
        }
    }

    struct Logout: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Discard the cached token.")

        @OptionGroup var options: StoreOptions

        func run() async throws {
            if let provider = try options.tokenProvider() as? DeviceCodeTokenProvider {
                await provider.signOut()
            }
            print("Signed out.")
        }
    }
}

// MARK: - Read

extension RulebookCLI {
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List rules, in evaluation order.")

        @OptionGroup var options: StoreOptions
        @Flag(name: .long, help: "Emit raw JSON instead of a table.") var json = false

        func run() async throws {
            let profile = try options.profile()
            let rules = try await options.store().listRules()
            print(json ? try Format.json(rules) : Format.table(rules, profile: profile))
        }
    }

    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print one rule as neutral JSON.")

        @OptionGroup var options: StoreOptions
        @Argument(help: "Rule id.") var id: String

        func run() async throws {
            print(try Format.json(try await options.store().rule(id: id)))
        }
    }

    struct Describe: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Write rules out in the provider's own words."
        )

        @OptionGroup var options: StoreOptions
        @Argument(help: "Rule id. Omit to describe every rule.") var id: String?
        @Option(name: .shortAndLong, help: "Describe a rule file instead of the mailbox.")
        var file: String?

        func run() async throws {
            let profile = try options.profile()

            let rules: [MailRule]
            if let file {
                rules = try Format.decodeRules(file)
            } else if let id {
                rules = [try await options.store().rule(id: id)]
            } else {
                rules = try await options.store().listRules()
            }

            guard !rules.isEmpty else {
                print("No \(profile.ruleNounPlural).")
                return
            }
            print(rules.map(profile.describe).joined(separator: "\n\n"))
        }
    }

    struct Export: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Write every rule to a JSON file.")

        @OptionGroup var options: StoreOptions
        @Option(name: .shortAndLong, help: "Destination file. Defaults to stdout.")
        var output: String?

        func run() async throws {
            let text = try Format.json(try await options.store().listRules())
            if let output {
                try text.write(toFile: output, atomically: true, encoding: .utf8)
                FileHandle.standardError.write(Data("Exported to \(output)\n".utf8))
            } else {
                print(text)
            }
        }
    }
}

// MARK: - Write

extension RulebookCLI {
    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a rule from a JSON file.")

        @OptionGroup var options: StoreOptions
        @Option(name: .shortAndLong, help: "JSON file holding one rule.") var file: String

        func run() async throws {
            let profile = try options.profile()
            let rule: MailRule = try Format.decode(file)
            try Gate.enforce(RuleValidator.validate(rule, for: profile.capabilities))

            let created = try await options.store().createRule(rule)
            print("Created \(created.id ?? "?") — \(created.name)")
        }
    }

    struct Update: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Patch an existing rule from a JSON file.")

        @OptionGroup var options: StoreOptions
        @Argument(help: "Rule id.") var id: String
        @Option(name: .shortAndLong, help: "JSON file holding the rule.") var file: String

        func run() async throws {
            let profile = try options.profile()
            let rule: MailRule = try Format.decode(file)
            try Gate.enforce(RuleValidator.validate(rule, for: profile.capabilities))

            let updated = try await options.store().updateRule(id: id, with: rule)
            print("Updated \(updated.id ?? id) — \(updated.name)")
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a rule.")

        @OptionGroup var options: StoreOptions
        @Argument(help: "Rule id.") var id: String
        @Flag(name: .long, help: "Skip the confirmation prompt.") var yes = false

        func run() async throws {
            let store = try options.store()
            let rule = try await store.rule(id: id)

            if !yes {
                print("Delete \"\(rule.name)\" (\(id))? [y/N] ", terminator: "")
                let answer = readLine()?.lowercased() ?? ""
                guard answer == "y" || answer == "yes" else {
                    print("Cancelled.")
                    return
                }
            }

            try await store.deleteRule(id: id)
            print("Deleted \(id).")
        }
    }

    struct Apply: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "apply",
            abstract: "Push a JSON file of rules to the mailbox, matching on name."
        )

        @OptionGroup var options: StoreOptions
        @Option(name: .shortAndLong, help: "JSON file holding an array of rules.") var file: String
        @Flag(name: .long, help: "Print the plan without changing anything.") var dryRun = false

        func run() async throws {
            let profile = try options.profile()
            let desired: [MailRule] = try Format.decodeRules(file)

            var issues = RuleValidator.validate(set: desired)
            issues += desired.flatMap { RuleCompatibility.check($0, against: profile.capabilities) }
            try Gate.enforce(issues)

            let store = try options.store()
            let existing = try await store.listRules()
            let byName = Dictionary(grouping: existing, by: \.name)

            // Refuse ambiguity up front rather than half-applying a file.
            let ambiguous = desired.map(\.name).filter { (byName[$0]?.count ?? 0) > 1 }
            guard ambiguous.isEmpty else {
                throw ValidationError("The mailbox has more than one rule named \(ambiguous.map { "\"\($0)\"" }.joined(separator: ", ")); rename them first.")
            }

            var done = 0
            for rule in desired {
                do {
                    if let match = byName[rule.name]?.first, let id = match.id {
                        if match.status.isReadOnly {
                            print("skip \(id) — \(rule.name) (read-only in the mailbox)")
                            continue
                        }
                        print("\(dryRun ? "would update" : "update") \(id) — \(rule.name)")
                        if !dryRun { _ = try await store.updateRule(id: id, with: rule) }
                    } else {
                        print("\(dryRun ? "would create" : "create") — \(rule.name)")
                        if !dryRun { _ = try await store.createRule(rule) }
                    }
                    done += 1
                } catch {
                    throw ValidationError("Stopped at \"\(rule.name)\" after \(done) of \(desired.count): \(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - Offline tools

extension RulebookCLI {
    struct Validate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Check a rule file — structure, and what the provider supports. Runs offline."
        )

        @OptionGroup var providerOption: ProviderOption
        @Option(name: .shortAndLong, help: "JSON file holding one rule or an array of rules.")
        var file: String
        @Flag(name: .long, help: "Skip provider capability checks; structure only.")
        var structureOnly = false

        func run() async throws {
            let profile = try providerOption.profile()
            let rules = try Format.decodeRules(file)

            var issues = RuleValidator.validate(set: rules)
            if !structureOnly {
                issues += rules.flatMap { RuleCompatibility.check($0, against: profile.capabilities) }
            }

            let scope = structureOnly ? "structure" : profile.displayName
            guard !issues.isEmpty else {
                print("\(rules.count) \(rules.count == 1 ? "rule" : "rules"): no issues (\(scope)).")
                return
            }
            for issue in issues { print(issue.description) }
            if issues.hasErrors { throw ExitCode.failure }
        }
    }

    struct Translate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show the native payload a neutral rule becomes for a provider."
        )

        @OptionGroup var providerOption: ProviderOption
        @Option(name: .shortAndLong, help: "JSON file holding one rule or an array of rules.")
        var file: String

        func run() async throws {
            let profile = try providerOption.profile()
            let rules = try Format.decodeRules(file)

            for rule in rules {
                print("// \(rule.name) → \(profile.displayName) \(profile.ruleNoun)")
                do {
                    switch profile.id {
                    case .microsoft:
                        print(try Format.json(try GraphRuleMapper().encode(rule)))
                    case .local:
                        print(try Format.json(rule))
                    }
                } catch let MappingError.unsupported(issues) {
                    for issue in issues { print(issue.description) }
                }
                print()
            }
        }
    }

    struct Folders: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List the mailbox's folders, with the ids rules reference."
        )

        @OptionGroup var options: StoreOptions
        @Flag(name: .long, help: "Show the opaque provider ids alongside the names.")
        var ids = false

        func run() async throws {
            let profile = try options.profile()
            guard profile.id == .microsoft else {
                throw ValidationError("Listing \(profile.folderNoun)s is only implemented for Outlook.")
            }

            let directory = GraphMailFolderDirectory(tokenProvider: try options.tokenProvider())
            let folders = try await directory.folders()

            guard !folders.isEmpty else {
                print("No \(profile.folderNoun)s returned.")
                return
            }
            for folder in folders {
                print(ids ? "\(Format.pad(folder.name ?? "?", 40))  \(folder.id ?? "-")" : (folder.name ?? "?"))
            }
        }
    }

    struct Providers: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show what each provider calls things and what it supports."
        )

        @Option(name: .shortAndLong, help: "Show one provider in detail.") var provider: String?

        func run() async throws {
            guard let name = provider else {
                print(Format.capabilityMatrix())
                return
            }
            guard let profile = ProviderCatalog.profile(named: name) else {
                throw ValidationError("Unknown provider \"\(name)\".")
            }
            print(Format.detail(of: profile))
        }
    }
}

// MARK: - Validation gate

enum Gate {
    /// Shared by the write commands: refuse to send a rule the provider will reject.
    static func enforce(_ issues: [ValidationIssue]) throws {
        for issue in issues {
            FileHandle.standardError.write(Data("\(issue.description)\n".utf8))
        }
        if issues.hasErrors {
            throw ValidationError("Rule has validation errors; nothing was sent.")
        }
    }
}

// MARK: - Formatting

enum Format {
    static func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func decode<T: Decodable>(_ path: String) throws -> T {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Accepts either a single rule or an array of them.
    static func decodeRules(_ path: String) throws -> [MailRule] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoder = JSONDecoder()
        // Decide by shape, so a mistake inside an array is reported as that
        // mistake, not as "expected a dictionary".
        if (try? JSONSerialization.jsonObject(with: data)) is [Any] {
            return try decoder.decode([MailRule].self, from: data)
        }
        return [try decoder.decode(MailRule.self, from: data)]
    }

    static func pad(_ text: String, _ width: Int) -> String {
        text.padding(toLength: Swift.max(width, text.count), withPad: " ", startingAt: 0)
    }

    static func table(_ rules: [MailRule], profile: ProviderProfile) -> String {
        guard !rules.isEmpty else { return "No \(profile.ruleNounPlural)." }

        let rows = rules.map { rule in
            (
                order: rule.order.map(String.init) ?? "-",
                id: rule.id ?? "-",
                state: rule.isEnabled ? "on" : "off",
                flags: [rule.status.hasError ? "error" : nil,
                        rule.status.isReadOnly ? "read-only" : nil]
                    .compactMap { $0 }.joined(separator: ","),
                name: rule.name
            )
        }

        let orderWidth = Swift.max(5, rows.map(\.order.count).max() ?? 5)
        let idWidth = Swift.max(2, rows.map(\.id.count).max() ?? 2)

        var lines = ["\(pad("ORDER", orderWidth))  \(pad("ID", idWidth))  STATE  \(profile.ruleNoun.uppercased())"]
        for row in rows {
            let suffix = row.flags.isEmpty ? "" : "  (\(row.flags))"
            lines.append("\(pad(row.order, orderWidth))  \(pad(row.id, idWidth))  \(pad(row.state, 5))  \(row.name)\(suffix)")
        }
        return lines.joined(separator: "\n")
    }

    static func capabilityMatrix() -> String {
        let profiles = ProviderCatalog.all.filter { $0.id != .local }
        var lines: [String] = []

        lines.append(profiles.map { "\($0.displayName) calls them \($0.ruleNounPlural); mail is filed in a \($0.folderNoun); tags are \($0.tagNoun) values." }.joined(separator: "\n"))
        lines.append("")

        let nameWidth = 22
        lines.append("\(pad("CONDITION", nameWidth))  " + profiles.map { pad($0.displayName, 9) }.joined(separator: " "))
        for kind in ConditionKind.allCases {
            let marks = profiles.map { pad($0.supports(kind) ? "yes" : "—", 9) }.joined(separator: " ")
            lines.append("\(pad(kind.rawValue, nameWidth))  \(marks)")
        }

        lines.append("")
        lines.append("\(pad("ACTION", nameWidth))  " + profiles.map { pad($0.displayName, 9) }.joined(separator: " "))
        for kind in ActionKind.allCases {
            let marks = profiles.map { pad($0.supports(kind) ? "yes" : "—", 9) }.joined(separator: " ")
            lines.append("\(pad(kind.rawValue, nameWidth))  \(marks)")
        }

        lines.append("")
        let traits: [(String, (ProviderProfile) -> Bool)] = [
            ("ordered", { $0.capabilities.supportsOrdering }),
            ("can be disabled", { $0.capabilities.supportsDisabling }),
            ("exceptions", { $0.capabilities.supportsExceptions }),
            ("named headers", { $0.capabilities.supportsNamedHeaders }),
        ]
        lines.append("\(pad("TRAIT", nameWidth))  " + profiles.map { pad($0.displayName, 9) }.joined(separator: " "))
        for (label, test) in traits {
            let marks = profiles.map { pad(test($0) ? "yes" : "—", 9) }.joined(separator: " ")
            lines.append("\(pad(label, nameWidth))  \(marks)")
        }

        return lines.joined(separator: "\n")
    }

    static func detail(of profile: ProviderProfile) -> String {
        var lines = [
            "\(profile.displayName) — calls them \(profile.ruleNounPlural), files into a \(profile.folderNoun), tags with a \(profile.tagNoun).",
            "",
            "Conditions it supports:",
        ]
        for kind in profile.availableConditions {
            lines.append("  \(pad(kind.rawValue, 18))  \(profile.vocabulary.name(for: kind))")
        }
        lines.append("")
        lines.append("Actions it supports:")
        for kind in profile.availableActions {
            lines.append("  \(pad(kind.rawValue, 18))  \(profile.vocabulary.name(for: kind))")
        }

        let missingConditions = ConditionKind.allCases.filter { !profile.supports($0) }
        let missingActions = ActionKind.allCases.filter { !profile.supports($0) }
        if !missingConditions.isEmpty || !missingActions.isEmpty {
            lines.append("")
            lines.append("Not supported: " + (missingConditions.map(\.rawValue) + missingActions.map(\.rawValue))
                .joined(separator: ", "))
        }

        return lines.joined(separator: "\n")
    }
}
