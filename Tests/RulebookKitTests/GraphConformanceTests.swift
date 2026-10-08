import Foundation
import Testing
import RulebookTesting

/// Keeps ``FakeGraph`` honest.
///
/// Replays every exchange recorded from real Graph (`Fixtures/graph/*.json`,
/// written by `GraphProbe`) against a fake seeded with the same mailbox, and
/// requires the same status and body. That makes the fake's behaviour
/// evidence rather than belief, so other suites can rely on it.
///
/// If Graph changes, re-record. This suite will then show exactly where the
/// fake has to follow.
@Suite("FakeGraph matches recorded Graph")
struct GraphConformanceTests {

    /// The order `GraphProbe` ran its scenarios in. They share one mailbox, so
    /// sequences in later recordings depend on rules made by earlier ones.
    static let scenarios = [
        "baseline", "predicates", "predicates-negated", "predicates-combined", "actions",
        "patch-exceptions", "patch-conditions", "patch-actions", "sequence", "size",
        "validation", "not-found", "folders", "size-bounds", "unnamed", "casing", "auth",
    ]

    @Test("Every recorded exchange gets the same answer from the fake")
    func replay() throws {
        let baseline = try Recording.load("baseline")
        let fake = FakeGraph(
            token: "probe-token",
            folders: baseline.folders,
            rootFolderID: try #require(baseline.folders.first?["parentFolderId"] as? String),
            categories: baseline.categories,
            rules: baseline.rules
        )

        var ids = IDMap()
        var checked = 0

        for name in Self.scenarios {
            let recording = try Recording.load(name)
            for (index, exchange) in recording.exchanges.enumerated() {
                let path = ids.toFake(exchange.path)
                let token = name == "auth" ? ["not-a-real-token", ""][index] : fake.token
                let response = fake.handle(
                    method: exchange.method,
                    url: URL(string: fake.baseURL.absoluteString + "/" + path)!,
                    headers: token.isEmpty ? [:] : ["Authorization": "Bearer \(token)"],
                    body: exchange.requestBody.map { try! JSONSerialization.data(withJSONObject: $0) }
                )

                let where_ = "\(name) #\(index) \(exchange.method) \(exchange.label ?? exchange.path)"
                #expect(response.status == exchange.status, "\(where_): status")

                if exchange.method == "POST", response.status == 201,
                   let recorded = (exchange.responseBody as? [String: Any])?["id"] as? String,
                   let made = (response.json as? [String: Any])?["id"] as? String {
                    ids.learn(recorded: recorded, fake: made)
                }

                let expected = Recording.normalize(exchange.responseBody)
                let actual = Recording.normalize(ids.toRecorded(response.json))
                #expect(
                    NSObject.isEqual(expected, actual),
                    "\(where_): body\n  recorded: \(Recording.text(expected))\n  fake:     \(Recording.text(actual))"
                )
                checked += 1
            }
        }

        #expect(checked > 250, "Expected the full recording set; replayed only \(checked).")
    }
}

// MARK: - Recordings

struct Recording {
    struct Exchange {
        let method: String
        let path: String
        let label: String?
        let status: Int
        let requestBody: Any?
        let responseBody: Any?
    }

    let exchanges: [Exchange]

    static func load(_ name: String) throws -> Recording {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/graph"),
            "Missing recording \(name).json"
        )
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let exchanges = (object["exchanges"] as? [[String: Any]] ?? []).map {
            Exchange(
                method: $0["method"] as! String,
                path: $0["path"] as! String,
                label: $0["label"] as? String,
                status: $0["status"] as! Int,
                requestBody: $0["requestBody"],
                responseBody: $0["responseBody"]
            )
        }
        return Recording(exchanges: exchanges)
    }

    /// The baseline's first exchange lists the mailbox's rules, its third the
    /// top-level folders, its last the categories.
    var rules: [[String: Any]] { value(at: 0) }
    var folders: [[String: Any]] { value(at: 2) }
    var categories: [[String: Any]] { value(at: exchanges.count - 1) }

    private func value(at index: Int) -> [[String: Any]] {
        ((exchanges[index].responseBody as? [String: Any])?["value"] as? [[String: Any]]) ?? []
    }

    /// Drops what legitimately differs between two servers: OData context
    /// URLs and per-request diagnostics.
    static func normalize(_ value: Any?) -> NSObject {
        func clean(_ value: Any) -> Any {
            switch value {
            case let dict as [String: Any]:
                var out: [String: Any] = [:]
                for (key, inner) in dict where key != "@odata.context" && key != "innerError" {
                    out[key] = clean(inner)
                }
                return out
            case let array as [Any]:
                return array.map(clean)
            default:
                return value
            }
        }
        guard let value, !(value is NSNull) else { return NSNull() }
        return clean(value) as! NSObject
    }

    static func text(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        else { return "\(value)" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Rule ids the fake mints differ from the ones Graph minted; translate.
struct IDMap {
    private var recordedToFake: [String: String] = [:]
    private var fakeToRecorded: [String: String] = [:]

    mutating func learn(recorded: String, fake: String) {
        recordedToFake[recorded] = fake
        fakeToRecorded[fake] = recorded
    }

    func toFake(_ path: String) -> String {
        var path = path
        for (recorded, fake) in recordedToFake where path.contains("/" + recorded) {
            path = path.replacingOccurrences(of: "/" + recorded, with: "/" + fake)
        }
        return path
    }

    func toRecorded(_ value: Any?) -> Any? {
        switch value {
        case let dict as [String: Any]:
            var out: [String: Any] = [:]
            for (key, inner) in dict {
                if key == "id", let id = inner as? String, let recorded = fakeToRecorded[id] {
                    out[key] = recorded
                } else {
                    out[key] = toRecorded(inner)
                }
            }
            return out
        case let array as [Any]:
            return array.map { toRecorded($0) as Any }
        default:
            return value
        }
    }
}

private extension NSObject {
    static func isEqual(_ a: NSObject, _ b: NSObject) -> Bool { a.isEqual(b) }
}
