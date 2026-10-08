import Foundation
import Testing
@testable import RulebookKit

@Suite("InMemoryRuleStore")
struct InMemoryStoreTests {

    @Test("Create assigns an id and the rule reads back")
    func createThenGet() async throws {
        let store = InMemoryRuleStore()
        let id = try #require(try await store.createRule(.stub(name: "Alpha")).id)
        #expect(try await store.rule(id: id).name == "Alpha")
    }

    @Test("Listing is ordered, and a rule created with no order goes last")
    func listIsOrdered() async throws {
        let store = InMemoryRuleStore()
        _ = try await store.createRule(.stub(name: "Third", order: 30))
        _ = try await store.createRule(.stub(name: "Unordered", order: nil))
        _ = try await store.createRule(.stub(name: "First", order: 10))

        #expect(try await store.listRules().map(\.name) == ["First", "Third", "Unordered"])
    }

    @Test("Update replaces, as Graph does: an empty list clears what was stored")
    func updateReplaces() async throws {
        let store = InMemoryRuleStore()
        var rule = MailRule.stub(name: "Alpha")
        rule.exceptions = [.subject(StringMatch("keep"))]
        let id = try #require(try await store.createRule(rule).id)

        var edited = try await store.rule(id: id)
        edited.name = "Alpha renamed"
        edited.exceptions = []
        edited.order = nil
        let updated = try await store.updateRule(id: id, with: edited)

        #expect(updated.name == "Alpha renamed")
        #expect(updated.exceptions.isEmpty)
        #expect(updated.conditions == [.subject(StringMatch("x"))])
        #expect(updated.order == 1, "A nil order keeps the stored position.")
    }

    @Test("Moving a rule renumbers 1…N, displacing the rest down")
    func moveIsDense() async throws {
        let store = InMemoryRuleStore()
        for name in ["A", "B", "C", "D"] { _ = try await store.createRule(.stub(name: name, order: nil)) }
        let d = try #require(try await store.listRules().last?.id)

        try await store.moveRule(id: d, toPosition: 2)
        let rules = try await store.listRules()
        #expect(rules.map(\.name) == ["A", "D", "B", "C"])
        #expect(rules.map(\.order) == [1, 2, 3, 4])
    }

    @Test("Ids are never reused, even for a store seeded from a file")
    func idsDoNotCollideWithSeeds() async throws {
        let seeded = InMemoryRuleStore(seed: [
            MailRule(id: "rule-1", name: "From file", order: 1, actions: [.markAsRead(true)]),
        ])
        let created = try await seeded.createRule(.stub(name: "New"))
        #expect(created.id != "rule-1")
        #expect(try await seeded.listRules().count == 2)
    }

    @Test("Delete removes it; deleting again reports notFound")
    func deleteReportsMissing() async throws {
        let store = InMemoryRuleStore()
        let id = try #require(try await store.createRule(.stub()).id)

        try await store.deleteRule(id: id)
        #expect(try await store.listRules().isEmpty)

        await #expect(throws: RuleStoreError.self) { try await store.deleteRule(id: id) }
    }

    @Test("A store can carry a provider's capabilities")
    func storeCarriesCapabilities() {
        let store = InMemoryRuleStore(capabilities: GraphRuleMapper.capabilities)
        #expect(store.capabilities.provider == .microsoft)
        #expect(store.capabilities.supportsOrdering)
    }
}

@Suite("JSONFileRuleStore")
struct FileStoreTests {

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("rulebook-test-\(UUID().uuidString).json")
    }

    @Test("A missing file starts empty")
    func absentFileIsEmpty() async throws {
        #expect(try await JSONFileRuleStore(url: temporaryURL()).listRules().isEmpty)
    }

    @Test("Mutations survive reopening the file")
    func writesPersist() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let first = try JSONFileRuleStore(url: url)
        let id = try #require(try await first.createRule(.stub(name: "Persisted", order: 7)).id)

        let second = try JSONFileRuleStore(url: url)
        let reloaded = try await second.rule(id: id)
        #expect(reloaded.name == "Persisted")
        #expect(reloaded.order == 7)
    }

    @Test("Deletes are persisted too")
    func deletesPersist() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try JSONFileRuleStore(url: url)
        let id = try #require(try await store.createRule(.stub()).id)
        try await store.deleteRule(id: id)

        #expect(try await JSONFileRuleStore(url: url).listRules().isEmpty)
    }

    @Test("What it writes is a valid rule set the CLI can re-read")
    func writtenFileRoundTrips() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try JSONFileRuleStore(url: url)
        _ = try await store.createRule(.stub(name: "A", order: 2))
        _ = try await store.createRule(.stub(name: "B", order: 1))

        let decoded = try JSONDecoder().decode([MailRule].self, from: try Data(contentsOf: url))
        #expect(decoded.map(\.name) == ["B", "A"], "Persisted in evaluation order")
        #expect(!RuleValidator.validate(set: decoded).hasErrors)
    }
}

// Serialized: these cases share the MockURLProtocol response queue.
@Suite("GraphRuleStore", .serialized)
struct GraphStoreTests {

    private func store(_ responses: [MockURLProtocol.Response]) -> GraphRuleStore {
        MockURLProtocol.queue(responses)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return GraphRuleStore(
            tokenProvider: StaticTokenProvider("test-token"),
            session: URLSession(configuration: configuration),
            // Folder resolution would issue its own requests and consume the
            // queued responses; it is covered separately below.
            resolveFolderNames: false
        )
    }

    @Test("Graph rules arrive as neutral rules")
    func listReturnsNeutralRules() async throws {
        let body = """
        {"value":[{"displayName":"B","sequence":2,
                   "conditions":{"senderContains":["x"]},
                   "actions":{"moveToFolder":"f1","stopProcessingRules":true}}]}
        """
        let rules = try await store([.init(status: 200, body: body)]).listRules()

        let rule = try #require(rules.first)
        #expect(rule.name == "B")
        #expect(rule.order == 2)
        #expect(rule.conditions == [.from(StringMatch(["x"]))])
        #expect(rule.actions == [.moveTo(.id("f1")), .stopProcessing])
    }

    @Test("List follows @odata.nextLink across pages")
    func listFollowsPaging() async throws {
        let page1 = """
        {"value":[{"displayName":"B","sequence":2,"actions":{"delete":true}}],
         "@odata.nextLink":"https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messageRules?$skip=1"}
        """
        let page2 = #"{"value":[{"displayName":"A","sequence":1,"actions":{"delete":true}}]}"#

        let rules = try await store([
            .init(status: 200, body: page1), .init(status: 200, body: page2),
        ]).listRules()

        #expect(rules.map(\.name) == ["A", "B"])
        #expect(MockURLProtocol.recordedRequests().count == 2)
    }

    @Test("Requests carry the bearer token")
    func sendsAuthorizationHeader() async throws {
        _ = try await store([.init(status: 200, body: #"{"value":[]}"#)]).listRules()
        let request = try #require(MockURLProtocol.recordedRequests().first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
    }

    @Test("Create sends the mapped Graph body, without server-owned properties")
    func createSendsMappedBody() async throws {
        let rule = MailRule.stub(name: "Mapped", actions: [.moveTo(.id("f1"))])
        _ = try await store([.init(status: 201, body: #"{"displayName":"Mapped","sequence":1}"#)])
            .createRule(rule)

        let body = try #require(MockURLProtocol.recordedBodies().first)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        #expect(object["displayName"] as? String == "Mapped")
        #expect((object["actions"] as? [String: Any])?["moveToFolder"] as? String == "f1")
        #expect(object["id"] == nil)
        #expect(object["hasError"] == nil)
    }

    @Test("A rule Outlook cannot express never reaches the network")
    func unsupportedRuleIsNotSent() async throws {
        let subject = store([.init(status: 201, body: "{}")])

        await #expect(throws: MappingError.self) {
            _ = try await subject.createRule(.stub(actions: [.archive]))
        }
        #expect(MockURLProtocol.recordedRequests().isEmpty)
    }

    @Test("Folder ids are resolved to names on the way out")
    func resolvesFolderNames() async throws {
        let rule = try #require(try await folderResolvingStore(
            body: #"{"value":[{"displayName":"Filed","sequence":1,"actions":{"moveToFolder":"folder-1"}}]}"#
        ).listRules().first)

        #expect(rule.action(.moveTo) == .moveTo(MailboxFolder(id: "folder-1", name: "Inbox/Reading")))
    }

    @Test("An unknown folder id is left as-is rather than dropped")
    func unresolvableFolderSurvives() async throws {
        let rule = try #require(try await folderResolvingStore(
            body: #"{"value":[{"displayName":"Filed","sequence":1,"actions":{"moveToFolder":"gone"}}]}"#
        ).listRules().first)

        #expect(rule.action(.moveTo) == .moveTo(.id("gone")))
    }

    /// A store whose folder directory is fixed, so resolution is exercised
    /// without the directory issuing requests of its own.
    private func folderResolvingStore(body: String) -> GraphRuleStore {
        MockURLProtocol.queue([.init(status: 200, body: body)])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]

        return GraphRuleStore(
            client: GraphMessageRuleClient(
                tokenProvider: StaticTokenProvider("test-token"),
                session: URLSession(configuration: configuration)
            ),
            folders: StaticFolderDirectory(["folder-1": "Inbox/Reading"])
        )
    }

    @Test("A Graph error surfaces its code and message")
    func mapsGraphErrors() async throws {
        let body = #"{"error":{"code":"ErrorInvalidIdMalformed","message":"Id is malformed."}}"#
        do {
            _ = try await store([.init(status: 400, body: body)]).listRules()
            Issue.record("Expected an error.")
        } catch let RuleStoreError.provider(provider, status, code, message) {
            #expect(provider == .microsoft)
            #expect(status == 400)
            #expect(code == "ErrorInvalidIdMalformed")
            #expect(message == "Id is malformed.")
        }
    }

    @Test("A 404 on a single rule becomes notFound")
    func mapsMissingRule() async throws {
        let subject = store([.init(status: 404, body: #"{"error":{"code":"ErrorItemNotFound"}}"#)])
        do {
            _ = try await subject.rule(id: "nope")
            Issue.record("Expected a notFound error.")
        } catch let RuleStoreError.notFound(id) {
            #expect(id == "nope")
        }
    }
}

// MARK: - URLProtocol stub

final class MockURLProtocol: URLProtocol {
    struct Response {
        var status: Int
        var body: String
    }

    private struct State {
        var queued: [Response] = []
        var requests: [URLRequest] = []
        var bodies: [Data] = []
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var state = State()

    static func queue(_ responses: [Response]) {
        lock.withLock { state = State(queued: responses) }
    }

    static func recordedRequests() -> [URLRequest] { lock.withLock { state.requests } }
    static func recordedBodies() -> [Data] { lock.withLock { state.bodies } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        // URLSession moves httpBody into a stream, so read it back out here.
        let body = request.httpBody ?? request.httpBodyStream.map(Self.drain) ?? Data()

        let next: Response? = Self.lock.withLock {
            Self.state.requests.append(request)
            if !body.isEmpty { Self.state.bodies.append(body) }
            return Self.state.queued.isEmpty ? nil : Self.state.queued.removeFirst()
        }

        guard let next, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }

        let response = HTTPURLResponse(
            url: url, statusCode: next.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(next.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }

        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

@Suite("Provider error text")
struct ProviderErrorTextTests {

    @Test("A Graph rule-validation error names the field in the app's own words")
    func namesTheField() {
        let error = RuleStoreError.provider(
            .microsoft, status: 400, code: "ErrorInvalidValue",
            message: "MessageRuleValidationError: ErrorCode: 'InvalidValue', "
                   + "Message: 'The value isn't valid.', Field: 'Sequence', Value: '0'."
        )
        let text = try! #require(error.errorDescription)

        #expect(text.contains("evaluation order"), "Should not say \"Sequence\": \(text)")
        #expect(text.contains("0"))
        #expect(!text.contains("MessageRuleValidationError"))
    }

    @Test("Known codes get plain sentences", arguments: [
        ("ErrorItemNotFound", "no longer exists"),
        ("ErrorQuotaExceeded", "as many rules as Outlook allows"),
        ("ErrorAccessDenied", "refused access"),
    ])
    func knownCodes(code: String, expected: String) {
        let error = RuleStoreError.provider(.microsoft, status: 400, code: code, message: "whatever")
        #expect(error.errorDescription?.contains(expected) == true)
    }

    @Test("An unrecognised error keeps the provider's own text rather than hiding it")
    func unknownFallsThrough() {
        let error = RuleStoreError.provider(
            .microsoft, status: 500, code: "SomethingNew", message: "A brand new failure."
        )
        let text = try! #require(error.errorDescription)

        #expect(text.contains("SomethingNew"))
        #expect(text.contains("A brand new failure."))
        #expect(text.contains("500"))
    }

    @Test("Every error real Graph returned reads as a sentence, not Graph's syntax")
    func recordedErrorsAreReadable() throws {
        var checked = 0
        for name in GraphConformanceTests.scenarios {
            for exchange in try Recording.load(name).exchanges where exchange.status >= 400 {
                let error = (exchange.responseBody as? [String: Any])?["error"] as? [String: Any]
                let failure = RuleStoreError.provider(
                    .microsoft, status: exchange.status,
                    code: error?["code"] as? String, message: error?["message"] as? String
                )
                let text = try #require(failure.errorDescription)
                #expect(!text.contains("ErrorCode:"), "\(exchange.label ?? exchange.path): \(text)")
                #expect(!text.contains("Field:"), "\(exchange.label ?? exchange.path): \(text)")
                #expect(text.count < 160, "\(exchange.label ?? exchange.path): \(text)")
                checked += 1
            }
        }
        #expect(checked > 20)
    }

    @Test("A folder Outlook can't find is named as the destination folder")
    func folderErrorWording() {
        let text = RuleStoreError.provider(.microsoft, status: 400, code: "MessageRuleValidationError",
            message: "ErrorCode: 'InvalidValue', Message: 'Id is malformed.', Field: 'Action.MoveToFolder', Value: 'Deleted Items'.").errorDescription
        #expect(text == "Outlook rejected the destination folder: \u{201C}Deleted Items\u{201D} isn\u{2019}t allowed.")
    }
}
