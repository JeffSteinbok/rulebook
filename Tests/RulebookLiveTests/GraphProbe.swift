import Foundation
import Testing
@testable import RulebookKit

/// Learns how Graph's `messageRules` endpoint actually behaves, and records it.
///
/// Unlike ``LiveOutlookWriteTests``, this does not go through the mapper: it
/// sends raw JSON, including payloads the mapper would refuse, because the
/// point is to find out what Graph accepts, what it echoes back, and how it
/// words its errors. Every exchange is written, sanitized, to
/// `Tests/RulebookKitTests/Fixtures/graph/`, where the hermetic suite's Graph
/// mock replays it.
///
///     RULEBOOK_LIVE=1 RULEBOOK_PROBE=1 RULEBOOK_CLIENT_ID=<id> \
///         swift test --filter GraphProbe
///
/// Run it against a **test mailbox only**. Every rule it creates is disabled,
/// named "RuleBook probe – …", and matches only `@example.invalid` senders;
/// all of them are deleted at the end, and any existing rule whose sequence
/// moved is put back.
@Suite("GraphProbe", .serialized, .enabled(if: Probe.isEnabled))
struct GraphProbeTests {

    @Test("Record Graph's behaviour for every predicate, action, and edge case")
    func probe() async throws {
        let probe = try await Probe.connect()
        let before = try await probe.snapshotSequences()

        await probe.sweep()   // a previous run that died half-way
        for scenario in Probe.scenarios {
            await probe.run(scenario)
        }
        await probe.sweep()
        try await probe.restoreSequences(before)

        try probe.recorder.write()
        print(probe.recorder.summary())
    }
}

// MARK: - Scenarios

extension Probe {
    typealias JSON = [String: Any]

    static let prefix = "RuleBook probe – "
    static let sender = "rulebook-probe@example.invalid"
    static let rulesPath = "me/mailFolders/inbox/messageRules"

    static func recipient(_ address: String = sender, name: String? = "Probe Recipient") -> JSON {
        var email: JSON = ["address": address]
        if let name { email["name"] = name }
        return ["emailAddress": email]
    }

    /// A disabled rule that can only match mail from `sender`.
    static func rule(
        _ name: String,
        conditions: JSON? = ["senderContains": [sender]],
        exceptions: JSON? = nil,
        actions: JSON? = ["markAsRead": true],
        sequence: Int? = 900,
        isEnabled: Bool = false
    ) -> JSON {
        var body: JSON = ["displayName": prefix + name, "isEnabled": isEnabled]
        if let sequence { body["sequence"] = sequence }
        if let conditions { body["conditions"] = conditions }
        if let exceptions { body["exceptions"] = exceptions }
        if let actions { body["actions"] = actions }
        return body
    }

    /// Every predicate field Graph documents, each with a sample value.
    nonisolated(unsafe) static let predicateSamples: [(String, Any)] = [
        ("bodyContains", ["rbprobe-body"]),
        ("bodyOrSubjectContains", ["rbprobe-either"]),
        ("categories", ["RuleBookProbe"]),
        ("fromAddresses", [recipient(name: "Probe Sender")]),
        ("hasAttachments", true),
        ("headerContains", ["X-RuleBook-Probe"]),
        ("importance", "high"),
        ("isApprovalRequest", true),
        ("isAutomaticForward", true),
        ("isAutomaticReply", true),
        ("isEncrypted", true),
        ("isMeetingRequest", true),
        ("isMeetingResponse", true),
        ("isNonDeliveryReport", true),
        ("isPermissionControlled", true),
        ("isReadReceipt", true),
        ("isSigned", true),
        ("isVoicemail", true),
        ("messageActionFlag", "followUp"),
        ("notSentToMe", true),
        ("recipientContains", ["rbprobe-recipient"]),
        ("senderContains", [sender]),
        ("sensitivity", "confidential"),
        ("sentCcMe", true),
        ("sentOnlyToMe", true),
        ("sentToAddresses", [recipient()]),
        ("sentToMe", true),
        ("sentToOrCcMe", true),
        ("subjectContains", ["rbprobe-subject"]),
        ("withinSizeRange", ["minimumSize": 10, "maximumSize": 200]),
    ]

    static let scenarios: [Scenario] = [
        Scenario("baseline", "What an account looks like before we touch it.") { p in
            await p.send("GET", rulesPath)
            await p.send("GET", rulesPath + "?$top=1")
            await p.send("GET", "me/mailFolders?includeHiddenFolders=true&$top=100")
            await p.send("GET", "me/mailFolders/inbox")
            await p.send("GET", "me/mailFolders/inbox/childFolders?includeHiddenFolders=true")
            await p.send("GET", "me/mailFolders/deleteditems")
            await p.send("GET", "me/mailFolders/junkemail")
            await p.send("GET", "me/outlook/masterCategories")
        },

        Scenario("predicates", "Each predicate alone: accepted? echoed back as sent?") { p in
            for (field, value) in predicateSamples {
                await p.createAndRead("predicate \(field)", rule("predicate \(field)", conditions: [field: value]))
            }
        },

        Scenario("predicates-negated", "Is a false boolean predicate kept, or dropped as no condition?") { p in
            for field in ["isMeetingRequest", "hasAttachments", "isEncrypted", "sentToMe"] {
                await p.createAndRead("negated \(field)", rule("negated \(field)", conditions: [field: false]))
            }
        },

        Scenario("predicates-combined", "Several predicates plus exceptions in one rule.") { p in
            await p.createAndRead("combined", rule(
                "combined",
                conditions: ["senderContains": [sender], "subjectContains": ["a", "b"], "hasAttachments": true],
                exceptions: ["bodyContains": ["unsubscribe"], "importance": "low"]
            ))
        },

        Scenario("actions", "Each action alone, including folders given by id, well-known name, and display name.") { p in
            let junk = await p.folderID("junkemail")
            let deleted = await p.folderID("deleteditems")
            let samples: [(String, Any)] = [
                ("assignCategories", ["RuleBookProbe"]),
                ("assignCategories-unknown", ["RuleBook category that does not exist"]),
                ("copyToFolder", junk ?? "missing"),
                ("delete", true),
                ("forwardAsAttachmentTo", [recipient()]),
                ("forwardTo", [recipient()]),
                ("markAsRead", true),
                ("markAsRead-false", false),
                ("markImportance", "low"),
                ("moveToFolder", deleted ?? "missing"),
                ("moveToFolder-wellknown", "deleteditems"),
                ("moveToFolder-displayname", "Deleted Items"),
                ("moveToFolder-bogus", "AAMkAGI2THIS-IS-NOT-A-FOLDER"),
                ("permanentDelete", true),
                ("redirectTo", [recipient()]),
                ("stopProcessingRules", true),
            ]
            for (label, value) in samples {
                let field = String(label.split(separator: "-").first!)
                await p.createAndRead("action \(label)", rule("action \(label)", actions: [field: value]))
            }
            await p.createAndRead("actions two moves", rule(
                "two moves", actions: ["moveToFolder": deleted ?? "", "copyToFolder": junk ?? ""]
            ))
        },

        Scenario("patch-exceptions", "Can a PATCH clear exceptions, and which spelling does it take?") { p in
            let body = rule("patch exceptions", exceptions: ["subjectContains": ["keep-me"]])
            guard let id = await p.createAndRead("create", body) else { return }
            await p.patchAndRead("omit exceptions", id, ["displayName": prefix + "patch exceptions renamed"])
            await p.patchAndRead("exceptions {}", id, ["exceptions": [String: Any]()])
            await p.patchAndRead("re-add", id, ["exceptions": ["subjectContains": ["keep-me"]]])
            await p.patchAndRead("exceptions null", id, ["exceptions": NSNull()])
            await p.patchAndRead("re-add 2", id, ["exceptions": ["subjectContains": ["keep-me"]]])
            await p.patchAndRead("exceptions all-null predicate", id, ["exceptions": ["subjectContains": NSNull()]])
        },

        Scenario("patch-conditions", "Does a PATCH replace the conditions object or merge into it?") { p in
            let body = rule("patch conditions", conditions: ["senderContains": [sender], "subjectContains": ["one"]])
            guard let id = await p.createAndRead("create", body) else { return }
            await p.patchAndRead("different predicate", id, ["conditions": ["bodyContains": ["two"]]])
            await p.patchAndRead("same predicate new value", id, ["conditions": ["bodyContains": ["three"]]])
            await p.patchAndRead("conditions {}", id, ["conditions": [String: Any]()])
            await p.patchAndRead("conditions null", id, ["conditions": NSNull()])
        },

        Scenario("patch-actions", "Does a PATCH replace actions, and can it leave a rule with none?") { p in
            let body = rule("patch actions", actions: ["markAsRead": true, "stopProcessingRules": true])
            guard let id = await p.createAndRead("create", body) else { return }
            await p.patchAndRead("different action", id, ["actions": ["markImportance": "high"]])
            await p.patchAndRead("actions {}", id, ["actions": [String: Any]()])
            await p.patchAndRead("actions null", id, ["actions": NSNull()])
            await p.patchAndRead("toggle only", id, ["isEnabled": false])
            await p.patchAndRead("full body", id, rule("patch actions full", actions: ["markAsRead": true]))
        },

        Scenario("sequence", "How Graph numbers rules: defaults, 0, negatives, duplicates, shifting.") { p in
            await p.listSequences("before")
            await p.createAndRead("no sequence", rule("no sequence", sequence: nil))
            await p.createAndRead("sequence 0", rule("sequence 0", sequence: 0))
            await p.createAndRead("sequence -1", rule("sequence -1", sequence: -1))
            let a = await p.createAndRead("dup a 901", rule("dup a", sequence: 901))
            let b = await p.createAndRead("dup b 901", rule("dup b", sequence: 901))
            await p.listSequences("after duplicates")
            await p.createAndRead("sequence 1", rule("sequence 1", sequence: 1))
            await p.listSequences("after inserting at 1")
            if let a, b != nil {
                await p.patchAndRead("move a to 1", a, ["sequence": 1])
                await p.listSequences("after moving a to 1")
            }
            await p.createAndRead("sequence huge", rule("sequence huge", sequence: 2_000_000_000))
            await p.listSequences("after huge")
        },

        Scenario("size", "withinSizeRange units and bounds.") { p in
            for (label, range) in [
                ("min only", ["minimumSize": 0]),
                ("max only", ["maximumSize": 1]),
                ("min > max", ["minimumSize": 500, "maximumSize": 100]),
                ("int max", ["maximumSize": Int(Int32.max)]),
                ("negative", ["minimumSize": -5]),
            ] as [(String, JSON)] {
                await p.createAndRead("size \(label)", rule("size \(label)", conditions: ["withinSizeRange": range]))
            }
        },

        Scenario("validation", "The error payloads Graph returns for bad rules.") { p in
            await p.create("empty name", ["displayName": "", "sequence": 900, "isEnabled": false,
                                          "actions": ["markAsRead": true]])
            await p.create("missing name", ["sequence": 900, "isEnabled": false, "actions": ["markAsRead": true]])
            await p.create("no actions", rule("no actions", actions: nil))
            await p.create("empty actions", rule("empty actions", actions: [String: Any]()))
            await p.create("no conditions", rule("no conditions", conditions: nil))
            await p.create("long name", rule("long " + String(repeating: "x", count: 300)))
            await p.create("bad address", rule("bad address", actions: ["forwardTo": [recipient("not an address")]]))
            await p.create("unknown field", rule("unknown field", conditions: ["notARealPredicate": true]))
            await p.create("bad enum", rule("bad enum", conditions: ["importance": "urgent"]))
            await p.create("wrong type", rule("wrong type", conditions: ["subjectContains": "not-an-array"]))
            await p.create("dup name 1", rule("dup name"))
            await p.create("dup name 2", rule("dup name"))
            await p.create("read-only fields", rule("read-only fields").merging(["isReadOnly": true, "hasError": true]) { $1 })
        },

        Scenario("not-found", "404s and malformed ids, for GET, PATCH and DELETE.") { p in
            let bogus = "AQAAAAAAAAA="
            await p.send("GET", rulesPath + "/" + bogus)
            await p.send("PATCH", rulesPath + "/" + bogus, body: ["isEnabled": false])
            await p.send("DELETE", rulesPath + "/" + bogus)
            await p.send("GET", rulesPath + "/not-base64")
            await p.send("GET", rulesPath + "/AQAA%2FAAA")
            if let id = await p.createAndRead("create then double delete", rule("double delete")) {
                await p.send("DELETE", rulesPath + "/" + p.escaped(id))
                await p.send("DELETE", rulesPath + "/" + p.escaped(id))
                await p.send("GET", rulesPath + "/" + p.escaped(id))
            }
        },

        Scenario("folders", "Which destinations a move keeps, and which Graph rewrites.") { p in
            for wellKnown in ["archive", "junkemail", "inbox", "deleteditems", "sentitems", "drafts"] {
                guard let id = await p.folderID(wellKnown) else { continue }
                await p.createAndRead("move to \(wellKnown)", rule("move to \(wellKnown)", actions: ["moveToFolder": id]))
                await p.createAndRead("copy to \(wellKnown)", rule("copy to \(wellKnown)", actions: ["copyToFolder": id]))
            }
            await p.createAndRead("move archive + stop", rule("move archive + stop", actions: [
                "moveToFolder": await p.folderID("archive") ?? "", "stopProcessingRules": true,
            ]))
            await p.createAndRead("delete + stop false", rule("delete + stop false", actions: [
                "delete": true, "stopProcessingRules": false,
            ]))
        },

        Scenario("size-bounds", "What an open-ended size range reads back as, and the largest size Graph takes.") { p in
            for (label, range) in [
                ("min 50 only", ["minimumSize": 50]),
                ("max 50 only", ["maximumSize": 50]),
                ("min 0 max 0", ["minimumSize": 0, "maximumSize": 0]),
                ("max 2097151", ["maximumSize": 2_097_151]),
                ("max 999999", ["maximumSize": 999_999]),
                ("max 102400", ["maximumSize": 102_400]),
                ("max 20000", ["maximumSize": 20_000]),
            ] as [(String, JSON)] {
                await p.createAndRead("size \(label)", rule("size \(label)", conditions: ["withinSizeRange": range]))
            }
        },

        Scenario("unnamed", "A rule with no displayName: how it reads back, alone and in the list.") { p in
            guard let id = await p.create("create unnamed", ["sequence": 900, "isEnabled": false,
                "conditions": ["senderContains": [sender]], "actions": ["markAsRead": true]]) else { return }
            await p.send("GET", rulesPath + "/" + p.escaped(id), label: "read back")
            await p.send("GET", rulesPath, label: "list containing an unnamed rule")
        },

        Scenario("casing", "Which string predicates Graph upper-cases, and whether exceptions are negatable.") { p in
            await p.createAndRead("mixed case", rule("mixed case", conditions: [
                "senderContains": ["MiXeD@Example.Invalid"],
                "recipientContains": ["MiXeD"],
                "subjectContains": ["MiXeD"],
                "bodyContains": ["MiXeD"],
                "headerContains": ["MiXeD"],
                "bodyOrSubjectContains": ["MiXeD"],
            ], actions: ["forwardTo": [recipient("MiXeD@Example.Invalid", name: "MiXeD Name")]]))
            await p.createAndRead("negated exception", rule(
                "negated exception", exceptions: ["isMeetingRequest": false, "hasAttachments": true]
            ))
            await p.createAndRead("enabled true", rule("enabled true", isEnabled: true))
        },

        Scenario("auth", "What a bad or missing token looks like.") { p in
            await p.send("GET", rulesPath, token: "not-a-real-token")
            await p.send("GET", rulesPath, token: "")
        },
    ]
}

// MARK: - Harness

struct Scenario: Sendable {
    let name: String
    let question: String
    let body: @Sendable (Probe) async -> Void

    init(_ name: String, _ question: String, body: @escaping @Sendable (Probe) async -> Void) {
        self.name = name
        self.question = question
        self.body = body
    }
}

final class Probe: @unchecked Sendable {
    static let isEnabled = Live.isEnabled && ProcessInfo.processInfo.environment["RULEBOOK_PROBE"] == "1"

    let token: String
    let base = URL(string: "https://graph.microsoft.com/v1.0/")!
    let recorder = Recorder()
    private var created: [String] = []
    private var folderIDs: [String: String] = [:]

    init(token: String) { self.token = token }

    static func connect() async throws -> Probe {
        let environment = ProcessInfo.processInfo.environment
        if let token = environment["RULEBOOK_ACCESS_TOKEN"], !token.isEmpty {
            return Probe(token: token)
        }
        guard let clientID = environment["RULEBOOK_CLIENT_ID"], !clientID.isEmpty else {
            throw Live.LiveTestError.noCredentials
        }
        let provider = DeviceCodeTokenProvider(
            configuration: .init(clientID: clientID, tenantID: environment["RULEBOOK_TENANT_ID"] ?? "common"),
            prompt: { _ in }
        )
        return Probe(token: try await provider.accessToken())
    }

    func run(_ scenario: Scenario) async {
        recorder.begin(scenario)
        await scenario.body(self)
        recorder.end()
    }

    // MARK: Requests

    struct Response {
        let status: Int
        let json: Any?
    }

    @discardableResult
    func send(_ method: String, _ path: String, body: Any? = nil, token: String? = nil, label: String? = nil) async -> Response {
        var request = URLRequest(url: URL(string: path, relativeTo: base)!)
        request.httpMethod = method
        let bearer = token ?? self.token
        if !bearer.isEmpty { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let response: Response
        do {
            let (data, urlResponse) = try await URLSession.shared.data(for: request)
            let status = (urlResponse as? HTTPURLResponse)?.statusCode ?? -1
            let json = data.isEmpty ? nil : try? JSONSerialization.jsonObject(with: data)
            response = Response(status: status, json: json ?? (data.isEmpty ? nil : String(decoding: data, as: UTF8.self)))
        } catch {
            response = Response(status: -1, json: "transport error: \(error)")
        }

        recorder.record(label: label, method: method, path: path, requestBody: body, response: response)
        return response
    }

    func escaped(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-_.~="))) ?? id
    }

    @discardableResult
    func create(_ label: String, _ body: JSON) async -> String? {
        let response = await send("POST", Self.rulesPath, body: body, label: label)
        guard (200..<300).contains(response.status),
              let id = (response.json as? JSON)?["id"] as? String else { return nil }
        created.append(id)
        return id
    }

    /// Create, then read it back: what Graph *stored* can differ from what the
    /// POST response claims.
    @discardableResult
    func createAndRead(_ label: String, _ body: JSON) async -> String? {
        guard let id = await create(label, body) else { return nil }
        await send("GET", Self.rulesPath + "/" + escaped(id), label: label + " (read back)")
        return id
    }

    func patchAndRead(_ label: String, _ id: String, _ body: JSON) async {
        await send("PATCH", Self.rulesPath + "/" + escaped(id), body: body, label: label)
        await send("GET", Self.rulesPath + "/" + escaped(id), label: label + " (read back)")
    }

    func listSequences(_ label: String) async {
        await send("GET", Self.rulesPath + "?$select=displayName,sequence", label: "sequences " + label)
    }

    func folderID(_ wellKnown: String) async -> String? {
        if let id = folderIDs[wellKnown] { return id }
        let response = await send("GET", "me/mailFolders/\(wellKnown)?$select=id,displayName", label: "resolve \(wellKnown)")
        let id = (response.json as? JSON)?["id"] as? String
        folderIDs[wellKnown] = id
        return id
    }

    // MARK: Safety

    func rules() async throws -> [JSON] {
        let response = await send("GET", Self.rulesPath, label: "list")
        guard response.status == 200, let value = (response.json as? JSON)?["value"] as? [JSON] else {
            throw ProbeError.unexpected(response.status, String(describing: response.json))
        }
        return value
    }

    func snapshotSequences() async throws -> [String: Int] {
        var result: [String: Int] = [:]
        for rule in try await rules() {
            guard let id = rule["id"] as? String, let name = rule["displayName"] as? String,
                  !name.hasPrefix(Self.prefix), let sequence = rule["sequence"] as? Int else { continue }
            result[id] = sequence
        }
        return result
    }

    /// Deletes every probe rule, including ones a crashed run left behind.
    func sweep() async {
        recorder.quietly = true
        defer { recorder.quietly = false }
        let names = (try? await rules()) ?? []
        let ids = Set(created).union(names.compactMap { rule in
            (rule["displayName"] as? String)?.hasPrefix(Self.prefix) == true ? rule["id"] as? String : nil
        })
        for id in ids { await send("DELETE", Self.rulesPath + "/" + escaped(id)) }
        created.removeAll()
    }

    func restoreSequences(_ before: [String: Int]) async throws {
        recorder.quietly = true
        defer { recorder.quietly = false }
        let after = try await snapshotSequences()
        for (id, sequence) in before where after[id] != sequence {
            await send("PATCH", Self.rulesPath + "/" + escaped(id), body: ["sequence": sequence])
            print("Restored sequence \(sequence) on existing rule \(id) (was \(after[id].map(String.init) ?? "gone")).")
        }
    }

    enum ProbeError: Error { case unexpected(Int, String) }
}

// MARK: - Recording

/// Collects exchanges per scenario and writes one sanitized fixture file each.
final class Recorder: @unchecked Sendable {
    var quietly = false
    private var current: (name: String, question: String, exchanges: [[String: Any]])?
    private var finished: [(name: String, question: String, exchanges: [[String: Any]])] = []

    func begin(_ scenario: Scenario) { current = (scenario.name, scenario.question, []) }
    func end() {
        if let current { finished.append(current) }
        current = nil
    }

    func record(label: String?, method: String, path: String, requestBody: Any?, response: Probe.Response) {
        guard !quietly, current != nil else { return }
        var exchange: [String: Any] = [
            "method": method,
            "path": path,
            "status": response.status,
        ]
        if let label { exchange["label"] = label }
        if let requestBody { exchange["requestBody"] = sanitize(requestBody) }
        if let json = response.json { exchange["responseBody"] = sanitize(json) }
        current?.exchanges.append(exchange)
    }

    static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("RulebookKitTests/Fixtures/graph", isDirectory: true)
    }

    func write() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        for scenario in finished {
            let file: [String: Any] = [
                "scenario": scenario.name,
                "question": scenario.question,
                "exchanges": scenario.exchanges,
            ]
            let data = try JSONSerialization.data(withJSONObject: file, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: Self.directory.appendingPathComponent("\(scenario.name).json"))
        }
    }

    func summary() -> String {
        finished.map { scenario in
            "== \(scenario.name)\n" + scenario.exchanges.map { e in
                let error = ((e["responseBody"] as? [String: Any])?["error"] as? [String: Any])
                let detail = error.map { " \($0["code"] ?? "") — \($0["message"] ?? "")" } ?? ""
                return "  \(e["status"]!) \(e["method"]!) \(e["label"] ?? e["path"]!)\(detail)"
            }.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    /// Strips what identifies the account, the people in it, or the request,
    /// and keeps everything that describes Graph's behaviour.
    ///
    /// The probe's own rules use `@example.invalid` and pass through as-is.
    /// Anything else came from the mailbox's existing rules: addresses become
    /// `personN@example.com` (keeping Graph's casing, which is itself
    /// behaviour worth recording) and rule names become "Existing rule N".
    func sanitize(_ value: Any) -> Any {
        switch value {
        case let dict as [String: Any]:
            let isForeignRule = dict["sequence"] != nil
                && (dict["displayName"] as? String).map { !$0.isEmpty && !$0.hasPrefix(Probe.prefix) } ?? false
            var out: [String: Any] = [:]
            for (key, inner) in dict {
                switch key {
                case "request-id", "client-request-id", "date":
                    out[key] = "<redacted>"
                case "displayName" where isForeignRule:
                    out[key] = alias(inner as? String ?? "", in: &ruleAliases, as: { "Existing rule \($0)" })
                default:
                    out[key] = sanitize(inner)
                }
            }
            return out
        case let array as [Any]:
            return array.map(sanitize)
        case let string as String:
            return redactAddresses(Self.redactUser(string))
        default:
            return value
        }
    }

    private var ruleAliases: [String: String] = [:]
    private var addressAliases: [String: String] = [:]

    private func alias(_ key: String, in table: inout [String: String], as make: (Int) -> String) -> String {
        if let existing = table[key] { return existing }
        let made = make(table.count + 1)
        table[key] = made
        return made
    }

    private func redactAddresses(_ string: String) -> String {
        let pattern = try! NSRegularExpression(pattern: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]+"#)
        var result = string
        for match in pattern.matches(in: string, range: NSRange(string.startIndex..., in: string)).reversed() {
            let range = Range(match.range, in: string)!
            let address = String(string[range])
            guard !address.lowercased().hasSuffix("@example.invalid") else { continue }
            var replacement = alias(address.lowercased(), in: &addressAliases, as: { "person\($0)@example.com" })
            if address == address.uppercased() { replacement = replacement.uppercased() }
            result.replaceSubrange(Range(match.range, in: result)!, with: replacement)
        }
        return result
    }

    /// `users('<guid or address>')` → `users('me')`.
    static func redactUser(_ string: String) -> String {
        string.replacingOccurrences(
            of: #"users\('[^']*'\)"#, with: "users('me')", options: .regularExpression
        )
    }
}

private extension Dictionary where Key == String, Value == Any {
    func merging(_ other: [String: Any], _ combine: (Any, Any) -> Any) -> [String: Any] {
        merging(other, uniquingKeysWith: combine)
    }
}
