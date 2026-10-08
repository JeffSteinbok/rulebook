import Foundation
import RulebookKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A stateful stand-in for the slice of Microsoft Graph the app uses:
/// `/me/mailFolders/inbox/messageRules`, `/me/mailFolders`, and
/// `/me/outlook/masterCategories`.
///
/// It does what *real* Graph does, including the parts that are surprising.
/// Each behaviour below was observed against a live mailbox and recorded under
/// `Tests/RulebookKitTests/Fixtures/graph/`. `GraphConformanceTests` replays
/// every one of those recordings against this fake, so if the fake drifts
/// from the recordings, that suite fails.
///
/// - Sequences stay dense (1…N). A write at position *k* inserts there and
///   shifts the rest down; anything past the end is clamped to N+1.
/// - PATCH replaces `conditions`, `exceptions` and `actions` whole. `{}`
///   clears conditions or exceptions; `null` is ignored; empty actions are a 400.
/// - A false boolean predicate or action is stored as nothing at all.
/// - `senderContains` and `recipientContains` are upper-cased.
/// - A move to Deleted Items becomes `delete`, and every delete gains
///   `stopProcessingRules`.
/// - A missing `withinSizeRange` bound is 0.
/// - A POST with no `displayName` creates nothing and returns the most
///   recently created rule.
///
/// Point a ``GraphRuleStore`` at it with ``makeStore(resolveFolderNames:)``,
/// or use ``session`` and ``baseURL`` directly.
public final class FakeGraph: @unchecked Sendable {

    public typealias JSON = [String: Any]

    /// The bearer token the fake accepts. Anything else is a 401.
    public let token: String
    public let baseURL: URL

    private let lock = NSLock()
    private var rules: [JSON] = []          // kept in sequence order
    private var folders: [JSON]
    private let rootFolderID: String
    private var categories: [JSON]
    private var lastCreatedID: String?
    private var nextRuleNumber: UInt32 = 0x1000
    private var faults: [Fault] = []
    private var log: [Request] = []

    /// One request as the fake received it.
    public struct Request: Sendable {
        public let method: String
        public let path: String
        public let query: String?
        public let body: Data?

        public var json: JSON? {
            body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? JSON }
        }
    }

    /// A failure the fake returns instead of handling a request.
    public struct Fault: Sendable {
        public var method: String?
        public var pathContains: String?
        public var status: Int
        public var code: String
        public var message: String
        public var headers: [String: String]
        public var remaining: Int

        public init(
            method: String? = nil, pathContains: String? = nil, status: Int,
            code: String = "ServiceUnavailable", message: String = "Injected failure.",
            headers: [String: String] = [:], times: Int = 1
        ) {
            self.method = method
            self.pathContains = pathContains
            self.status = status
            self.code = code
            self.message = message
            self.headers = headers
            self.remaining = times
        }
    }

    /// - Parameters:
    ///   - folders: Graph `mailFolder` objects. Defaults to ``standardFolders``.
    ///   - rules: Graph `messageRule` objects already in the mailbox. Each needs
    ///     an `id`; they are stored in the order given and renumbered 1…N.
    public init(
        token: String = "fake-graph-token",
        folders: [JSON]? = nil,
        rootFolderID: String = FakeGraph.standardRootID,
        categories: [JSON]? = nil,
        rules: [JSON] = []
    ) {
        self.token = token
        self.baseURL = URL(string: "https://\(UUID().uuidString.lowercased()).fake-graph.test/v1.0")!
        self.folders = folders ?? Self.standardFolders
        self.rootFolderID = rootFolderID
        self.categories = categories ?? Self.standardCategories
        self.rules = rules
        renumber()
        FakeGraphURLProtocol.register(self)
    }

    deinit { FakeGraphURLProtocol.unregister(self) }

    // MARK: - Wiring

    /// A session whose requests to ``baseURL`` are answered by this fake.
    public var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeGraphURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    public var tokenProvider: StaticTokenProvider { StaticTokenProvider(token) }

    public func makeStore(resolveFolderNames: Bool = true) -> GraphRuleStore {
        GraphRuleStore(
            tokenProvider: tokenProvider, baseURL: baseURL, session: session,
            resolveFolderNames: resolveFolderNames
        )
    }

    public func makeFolderDirectory() -> GraphMailFolderDirectory {
        GraphMailFolderDirectory(tokenProvider: tokenProvider, baseURL: baseURL, session: session)
    }

    // MARK: - Inspection and control

    /// The stored rules, in sequence order, exactly as Graph would return them.
    public var storedRules: [JSON] { lock.withLock { rules.map(present) } }

    public func storedRule(named name: String) -> JSON? {
        storedRules.first { $0["displayName"] as? String == name }
    }

    public var requests: [Request] { lock.withLock { log } }

    /// Requests that changed something.
    public var writes: [Request] { requests.filter { $0.method != "GET" } }

    public func clearRequestLog() { lock.withLock { log.removeAll() } }

    public func inject(_ fault: Fault) { lock.withLock { faults.append(fault) } }

    /// Marks a rule as one an administrator or another client owns.
    public func setReadOnly(_ id: String, _ readOnly: Bool = true) {
        lock.withLock {
            guard let index = rules.firstIndex(where: { $0["id"] as? String == id }) else { return }
            rules[index]["isReadOnly"] = readOnly
        }
    }

    public func folderID(wellKnownName: String) -> String? {
        lock.withLock { folders.first { $0["wellKnownName"] as? String == wellKnownName }?["id"] as? String }
    }

    public func folderID(named displayName: String) -> String? {
        lock.withLock { folders.first { $0["displayName"] as? String == displayName }?["id"] as? String }
    }

    // MARK: - Request handling

    public struct Response {
        public let status: Int
        public let headers: [String: String]
        public let body: Data?

        public var json: Any? { body.flatMap { try? JSONSerialization.jsonObject(with: $0) } }
    }

    public func handle(method: String, url: URL, headers: [String: String], body: Data?) -> Response {
        lock.withLock {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            // Graph decodes %2F before routing, so an encoded slash splits a segment.
            let decodedPath = (components?.percentEncodedPath ?? url.path).removingPercentEncoding ?? url.path
            let basePath = baseURL.path
            var path = decodedPath.hasPrefix(basePath) ? String(decodedPath.dropFirst(basePath.count)) : decodedPath
            if path.hasPrefix("/") { path.removeFirst() }
            let query = components?.queryItems ?? []

            log.append(Request(method: method, path: path, query: components?.query, body: body))

            if let index = faults.firstIndex(where: {
                ($0.method == nil || $0.method == method)
                    && ($0.pathContains.map { path.contains($0) } ?? true)
            }) {
                let fault = faults[index]
                faults[index].remaining -= 1
                if faults[index].remaining <= 0 { faults.remove(at: index) }
                return error(fault.status, fault.code, fault.message, headers: fault.headers)
            }

            let authorization = headers.first { $0.key.lowercased() == "authorization" }?.value ?? ""
            let bearer = authorization.hasPrefix("Bearer ") ? String(authorization.dropFirst(7)) : authorization
            if bearer.isEmpty {
                return error(401, "InvalidAuthenticationToken", "Access token is empty.")
            }
            if bearer != token {
                return error(401, "InvalidAuthenticationToken",
                             "Protocol 'Bearer' failed to validate because The token could not be read.")
            }

            return route(method: method, path: path, query: query, body: body)
        }
    }

    private func route(method: String, path: String, query: [URLQueryItem], body: Data?) -> Response {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let select = query.first { $0.name == "$select" }?.value?.split(separator: ",").map(String.init)

        // me/mailFolders/inbox/messageRules[/id]
        if segments.count >= 4, segments[0] == "me", segments[1] == "mailFolders",
           segments[2] == "inbox", segments[3] == "messageRules" {
            switch segments.count {
            case 4:
                switch method {
                case "GET": return listRules(select: select)
                case "POST": return createRule(body)
                default: return error(405, "BadRequest", "Method not allowed.")
                }
            case 5:
                let id = segments[4]
                switch method {
                case "GET": return getRule(id)
                case "PATCH": return updateRule(id, body)
                case "DELETE": return deleteRule(id)
                default: return error(405, "BadRequest", "Method not allowed.")
                }
            default:
                return error(400, "BadRequest", "Resource not found for the segment '\(segments.last!)'.")
            }
        }

        if segments == ["me", "outlook", "masterCategories"], method == "GET" {
            return ok(["@odata.context": context("outlook/masterCategories"), "value": categories])
        }

        // me/mailFolders, me/mailFolders/{id}, me/mailFolders/{id}/childFolders
        if segments.count >= 2, segments[0] == "me", segments[1] == "mailFolders", method == "GET" {
            let hidden = query.first { $0.name == "includeHiddenFolders" }?.value == "true"
            func visible(_ folder: JSON) -> Bool { hidden || folder["isHidden"] as? Bool != true }

            if segments.count == 2 {
                let roots = folders.filter { $0["parentFolderId"] as? String == rootFolderID && visible($0) }
                return ok(["@odata.context": context("mailFolders"), "value": roots.map { selecting($0, select) }])
            }
            guard let folder = folder(segments[2]) else {
                return error(404, "ErrorItemNotFound", "The specified object was not found in the store.")
            }
            if segments.count == 3 {
                var body = selecting(folder, select)
                body["@odata.context"] = context("mailFolders/$entity")
                return ok(body)
            }
            if segments.count == 4, segments[3] == "childFolders" {
                let children = folders.filter { $0["parentFolderId"] as? String == folder["id"] as? String && visible($0) }
                return ok(["@odata.context": context("mailFolders('\(segments[2])')/childFolders"),
                           "value": children.map { selecting($0, select) }])
            }
        }

        return error(400, "BadRequest", "Resource not found for the segment '\(segments.last ?? "")'.")
    }

    // MARK: Rules

    private func listRules(select: [String]?) -> Response {
        ok(["@odata.context": context("mailFolders('inbox')/messageRules"),
            "value": rules.map { selecting(present($0), select) }])
    }

    private func getRule(_ id: String) -> Response {
        guard let rule = rules.first(where: { $0["id"] as? String == id }) else { return notFound() }
        return ok(entity(rule))
    }

    private func createRule(_ body: Data?) -> Response {
        guard let object = parse(body) else { return deserializeError() }
        if let failure = checkShape(object) { return failure }

        // Graph quirk: with no displayName, nothing is created and the most
        // recently created rule comes back as though it were new.
        if object["displayName"] == nil || object["displayName"] is NSNull {
            if let id = lastCreatedID, let rule = rules.first(where: { $0["id"] as? String == id }) {
                return ok(entity(rule), status: 201)
            }
            return validation("EmptyValueFound", "The value must not be empty.", field: "Name", value: "")
        }

        var rule: JSON = ["id": makeRuleID(), "isEnabled": object["isEnabled"] as? Bool ?? true,
                          "hasError": false, "isReadOnly": false]
        switch applyFields(object, to: &rule, creating: true) {
        case .failure(let response): return response
        case .success(let sequence):
            insert(rule, at: sequence ?? 0)
            lastCreatedID = rule["id"] as? String
            let stored = rules.first { $0["id"] as? String == rule["id"] as? String }!
            return ok(entity(stored), status: 201)
        }
    }

    private func updateRule(_ id: String, _ body: Data?) -> Response {
        guard let index = rules.firstIndex(where: { $0["id"] as? String == id }) else { return notFound() }
        guard let object = parse(body) else { return deserializeError() }
        if let failure = checkShape(object) { return failure }

        var rule = rules[index]
        switch applyFields(object, to: &rule, creating: false) {
        case .failure(let response): return response
        case .success(let sequence):
            rules[index] = rule
            if let sequence {
                rules.remove(at: index)
                insert(rule, at: sequence)
            }
            let stored = rules.first { $0["id"] as? String == id }!
            return ok(entity(stored))
        }
    }

    private func deleteRule(_ id: String) -> Response {
        guard let index = rules.firstIndex(where: { $0["id"] as? String == id }) else { return notFound() }
        rules.remove(at: index)
        renumber()
        return Response(status: 204, headers: [:], body: nil)
    }

    private enum Applied {
        case success(sequence: Int?)
        case failure(Response)
    }

    /// Validates and applies the writable fields of a POST or PATCH body, in
    /// the order Graph reports problems.
    private func applyFields(_ object: JSON, to rule: inout JSON, creating: Bool) -> Applied {
        var sequence: Int?

        if let name = object["displayName"], !(name is NSNull) {
            let name = name as? String ?? ""
            if name.isEmpty {
                return .failure(validation("EmptyValueFound", "The value must not be empty.", field: "Name", value: ""))
            }
            if name.count > 256 {
                return .failure(validation("StringValueTooBig",
                    "The string is too long. The maximum allowed length is 256 characters.", field: "Name", value: name))
            }
            rule["displayName"] = name
        }

        if creating || object["sequence"] != nil {
            let value = object["sequence"] as? Int ?? 0
            if value < 1 {
                return .failure(validation("InvalidValue", "The value isn't valid.", field: "Sequence", value: "\(value)"))
            }
            sequence = value
        }

        if let enabled = object["isEnabled"] as? Bool { rule["isEnabled"] = enabled }

        for key in ["conditions", "exceptions"] {
            guard let value = object[key], !(value is NSNull) else { continue }
            switch normalizePredicates(value as? JSON ?? [:]) {
            case .failure(let response): return .failure(response)
            case .success(let predicates):
                rule[key] = predicates.isEmpty ? nil : predicates
            }
        }

        if creating || (object["actions"] != nil && !(object["actions"] is NSNull)) {
            switch normalizeActions(object["actions"] as? JSON ?? [:]) {
            case .failure(let response): return .failure(response)
            case .success(let actions): rule["actions"] = actions
            }
        }

        return .success(sequence: sequence)
    }

    private enum Normalized {
        case success(JSON)
        case failure(Response)
    }

    private func normalizePredicates(_ input: JSON) -> Normalized {
        var out: JSON = [:]
        for (key, value) in input {
            switch Self.predicateFields[key] {
            case .bool:
                if value as? Bool == true { out[key] = true }
            case .strings:
                let values = value as! [Any]
                let strings = values.compactMap { $0 as? String }
                out[key] = Self.upperCased.contains(key) ? strings.map { $0.uppercased() } : strings
            case .enumeration:
                out[key] = value
            case .recipients:
                out[key] = value
            case .size:
                let range = value as! JSON
                let minimum = range["minimumSize"] as? Int ?? 0
                let maximum = range["maximumSize"] as? Int ?? 0
                if minimum < 0 || maximum < 0 {
                    return .failure(validation("SizeLessThanZero", "The size that's specified can't be less than zero.",
                                               field: "Condition.WithinSizeRange", value: "\(min(minimum, maximum))"))
                }
                if maximum > Self.maximumSizeKB {
                    return .failure(validation("InvalidValue", "The value isn't valid.",
                                               field: "Condition.WithinSizeRange", value: "\(maximum)"))
                }
                if minimum > maximum {
                    return .failure(validation("InvalidSizeRange",
                        "The size range is invalid. The minimum size \(minimum) is greater than the maximum size \(maximum).",
                        field: "Condition.WithinSizeRange", value: "\(minimum),\(maximum)"))
                }
                out[key] = ["minimumSize": minimum, "maximumSize": maximum]
            case .folder, nil:
                break   // checkShape already refused unknown keys
            }
        }
        return .success(out)
    }

    private func normalizeActions(_ input: JSON) -> Normalized {
        var out: JSON = [:]
        for (key, value) in input {
            switch Self.actionFields[key] {
            case .bool:
                if value as? Bool == true { out[key] = true }
            case .folder:
                let reference = value as? String ?? ""
                guard let folder = folder(reference) else {
                    let field = key == "moveToFolder" ? "Action.MoveToFolder" : "Action.CopyToFolder"
                    return .failure(validation("InvalidValue", "Id is malformed.", field: field,
                                               value: Self.graphBase64(reference)))
                }
                if key == "moveToFolder", folder["wellKnownName"] as? String == "deleteditems" {
                    out["delete"] = true
                } else {
                    out[key] = folder["id"]
                }
            case .recipients:
                for recipient in value as? [JSON] ?? [] {
                    let address = (recipient["emailAddress"] as? JSON)?["address"] as? String ?? ""
                    if !Self.isAddress(address) {
                        let field = "Action." + key.prefix(1).uppercased() + key.dropFirst()
                        return .failure(validation("InvalidAddress", "The address isn't valid.",
                                                   field: field, value: ":" + address))
                    }
                }
                out[key] = value
            case .strings, .enumeration:
                out[key] = value
            default:
                break
            }
        }
        // An explicit delete always stops later rules. A move to Deleted Items
        // is *stored* as a delete, but does not gain the stop.
        if input["delete"] as? Bool == true || input["permanentDelete"] as? Bool == true {
            out["stopProcessingRules"] = true
        }
        if out.isEmpty {
            return .failure(validation("MissingAction", "Please choose at least one action.", field: "Actions", value: ""))
        }
        return .success(out)
    }

    /// The OData deserialization layer: unknown properties, wrong types, bad
    /// enum members and nulls inside a predicate fail before any rule logic.
    private func checkShape(_ object: JSON) -> Response? {
        for key in ["conditions", "exceptions", "actions"] {
            guard let value = object[key], !(value is NSNull) else { continue }
            guard let inner = value as? JSON else { return deserializeError() }
            let schema = key == "actions" ? Self.actionFields : Self.predicateFields
            for (field, fieldValue) in inner {
                guard let type = schema[field] else { return deserializeError() }
                if fieldValue is NSNull {
                    let edm = type == .strings ? "Collection(Edm.String)[Nullable=True]" : type.edmName
                    return error(400, "RequestBodyRead",
                        "A null value was found for the property named '\(field)', which has the expected type '\(edm)'. The expected type '\(edm)' cannot be null but it can have null values.")
                }
                if let failure = check(fieldValue, is: type, field: field) { return failure }
            }
        }
        return nil
    }

    private func check(_ value: Any, is type: FieldType, field: String) -> Response? {
        switch type {
        case .bool:
            guard value is Bool else { return deserializeError() }
        case .strings:
            guard let array = value as? [Any], array.allSatisfy({ $0 is String }) else { return deserializeError() }
        case .folder:
            guard value is String else { return deserializeError() }
        case .recipients:
            guard let array = value as? [Any], array.allSatisfy({ $0 is JSON }) else { return deserializeError() }
        case .size:
            guard value is JSON else { return deserializeError() }
        case .enumeration:
            guard let string = value as? String else { return deserializeError() }
            let allowed = Self.enumerations[field] ?? []
            if !allowed.contains(string) {
                return error(400, "RequestBodyRead", "Requested value '\(string)' was not found.")
            }
        }
        return nil
    }

    // MARK: Helpers

    private func insert(_ rule: JSON, at sequence: Int) {
        let index = max(0, min(sequence - 1, rules.count))
        rules.insert(rule, at: index)
        renumber()
    }

    /// Graph re-saves a rule whose sequence shifts, and a re-saved delete
    /// gains `stopProcessingRules` — so a move to Deleted Items, stored as a
    /// bare delete, picks up the stop the first time another rule moves past it.
    private func renumber() {
        for index in rules.indices {
            let sequence = index + 1
            if let previous = rules[index]["sequence"] as? Int, previous != sequence,
               var actions = rules[index]["actions"] as? JSON,
               actions["delete"] as? Bool == true || actions["permanentDelete"] as? Bool == true {
                actions["stopProcessingRules"] = true
                rules[index]["actions"] = actions
            }
            rules[index]["sequence"] = sequence
        }
    }

    private func makeRuleID() -> String {
        nextRuleNumber += 1
        var bytes: [UInt8] = [1, 0, 0, 0]
        withUnsafeBytes(of: nextRuleNumber.bigEndian) { bytes.append(contentsOf: $0) }
        return Data(bytes).base64EncodedString()
    }

    private func folder(_ reference: String) -> JSON? {
        folders.first { $0["id"] as? String == reference || $0["wellKnownName"] as? String == reference }
    }

    private func present(_ rule: JSON) -> JSON {
        rule.filter { !($0.value is NSNull) }
    }

    private func entity(_ rule: JSON) -> JSON {
        var body = present(rule)
        body["@odata.context"] = context("mailFolders('inbox')/messageRules/$entity")
        return body
    }

    private func selecting(_ object: JSON, _ select: [String]?) -> JSON {
        guard let select else { return object }
        return object.filter { $0.key == "id" || select.contains($0.key) }
    }

    private func context(_ suffix: String) -> String {
        "https://graph.microsoft.com/v1.0/$metadata#users('me')/\(suffix)"
    }

    private func parse(_ body: Data?) -> JSON? {
        guard let body, !body.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? JSON
    }

    private func ok(_ body: JSON, status: Int = 200) -> Response {
        Response(status: status, headers: ["Content-Type": "application/json"],
                 body: try? JSONSerialization.data(withJSONObject: body))
    }

    private func error(_ status: Int, _ code: String, _ message: String, headers: [String: String] = [:]) -> Response {
        var all = headers
        all["Content-Type"] = "application/json"
        return Response(status: status, headers: all, body: try? JSONSerialization.data(
            withJSONObject: ["error": ["code": code, "message": message]]
        ))
    }

    private func validation(_ errorCode: String, _ message: String, field: String, value: String) -> Response {
        error(400, "MessageRuleValidationError",
              "ErrorCode: '\(errorCode)', Message: '\(message)', Field: '\(field)', Value: '\(value)'.")
    }

    private func notFound() -> Response {
        error(404, "ErrorMessageRuleNotFound", "The specified object was not found in the store.")
    }

    private func deserializeError() -> Response {
        error(400, "UnableToDeserializePostBody", "were unable to deserialize ")
    }

    /// Graph echoes an unrecognised folder id in standard base64, not the
    /// URL-safe alphabet it was sent in.
    private static func graphBase64(_ value: String) -> String {
        value.replacingOccurrences(of: "-", with: "/").replacingOccurrences(of: "_", with: "+")
    }

    private static func isAddress(_ value: String) -> Bool {
        let parts = value.split(separator: "@")
        return parts.count == 2 && !value.contains(" ") && parts[1].contains(".")
    }

    // MARK: - Schema

    private enum FieldType {
        case bool, strings, enumeration, recipients, size, folder

        var edmName: String {
            switch self {
            case .bool: "Edm.Boolean"
            case .strings: "Collection(Edm.String)"
            case .enumeration: "Edm.String"
            case .recipients: "Collection(microsoft.graph.recipient)"
            case .size: "microsoft.graph.sizeRange"
            case .folder: "Edm.String"
            }
        }
    }

    /// The largest `maximumSize` Graph was seen to accept, in kilobytes
    /// (2 GB). 2147483647 is refused; nothing in between was probed.
    public static let maximumSizeKB = 2_097_151

    private static let upperCased: Set<String> = ["senderContains", "recipientContains"]

    private static let predicateFields: [String: FieldType] = [
        "bodyContains": .strings, "bodyOrSubjectContains": .strings, "categories": .strings,
        "fromAddresses": .recipients, "hasAttachments": .bool, "headerContains": .strings,
        "importance": .enumeration, "isApprovalRequest": .bool, "isAutomaticForward": .bool,
        "isAutomaticReply": .bool, "isEncrypted": .bool, "isMeetingRequest": .bool,
        "isMeetingResponse": .bool, "isNonDeliveryReport": .bool, "isPermissionControlled": .bool,
        "isReadReceipt": .bool, "isSigned": .bool, "isVoicemail": .bool,
        "messageActionFlag": .enumeration, "notSentToMe": .bool, "recipientContains": .strings,
        "senderContains": .strings, "sensitivity": .enumeration, "sentCcMe": .bool,
        "sentOnlyToMe": .bool, "sentToAddresses": .recipients, "sentToMe": .bool,
        "sentToOrCcMe": .bool, "subjectContains": .strings, "withinSizeRange": .size,
    ]

    private static let actionFields: [String: FieldType] = [
        "assignCategories": .strings, "copyToFolder": .folder, "delete": .bool,
        "forwardAsAttachmentTo": .recipients, "forwardTo": .recipients, "markAsRead": .bool,
        "markImportance": .enumeration, "moveToFolder": .folder, "permanentDelete": .bool,
        "redirectTo": .recipients, "stopProcessingRules": .bool,
    ]

    private static let enumerations: [String: Set<String>] = [
        "importance": ["low", "normal", "high"],
        "markImportance": ["low", "normal", "high"],
        "sensitivity": ["normal", "personal", "private", "confidential"],
        "messageActionFlag": ["any", "call", "doNotForward", "followUp", "fyi", "forward",
                              "noResponseNecessary", "read", "reply", "replyToAll", "review"],
    ]

    // MARK: - A standard mailbox

    public static let standardRootID = "fake-root"

    /// The well-known folders every Outlook mailbox has, plus a few of the
    /// kind people make, one of them nested.
    public static var standardFolders: [JSON] {
        func folder(_ id: String, _ name: String, parent: String = standardRootID,
                    wellKnown: String? = nil, children: Int = 0, hidden: Bool = false) -> JSON {
            var folder: JSON = ["id": id, "displayName": name, "parentFolderId": parent,
                                "childFolderCount": children, "isHidden": hidden,
                                "totalItemCount": 0, "unreadItemCount": 0, "sizeInBytes": 0]
            if let wellKnown { folder["wellKnownName"] = wellKnown }
            return folder
        }
        return [
            folder("fake-archive", "Archive", wellKnown: "archive"),
            folder("fake-deleted", "Deleted Items", wellKnown: "deleteditems"),
            folder("fake-drafts", "Drafts", wellKnown: "drafts"),
            folder("fake-inbox", "Inbox", wellKnown: "inbox", children: 2),
            folder("fake-junk", "Junk Email", wellKnown: "junkemail"),
            folder("fake-outbox", "Outbox", wellKnown: "outbox"),
            folder("fake-sent", "Sent Items", wellKnown: "sentitems"),
            folder("fake-receipts", "Receipts", parent: "fake-inbox"),
            folder("fake-newsletters", "Newsletters", parent: "fake-inbox", children: 1),
            folder("fake-tech", "Tech", parent: "fake-newsletters"),
            folder("fake-hidden", "Sync Issues", hidden: true),
        ]
    }

    public static var standardCategories: [JSON] { [
        ["id": "cat-red", "displayName": "Red category", "color": "preset0"],
        ["id": "cat-blue", "displayName": "Blue category", "color": "preset7"],
    ] }
}

// MARK: - URLProtocol

/// Routes requests to whichever ``FakeGraph`` owns their host, so fakes in
/// concurrently running tests never see each other's traffic.
public final class FakeGraphURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fakes: [String: WeakFake] = [:]

    private struct WeakFake { weak var fake: FakeGraph? }

    static func register(_ fake: FakeGraph) {
        lock.withLock { fakes[fake.baseURL.host!] = WeakFake(fake: fake) }
    }

    static func unregister(_ fake: FakeGraph) {
        lock.withLock { _ = fakes.removeValue(forKey: fake.baseURL.host!) }
    }

    override public class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return lock.withLock { fakes[host] != nil }
    }

    override public class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override public func stopLoading() {}

    override public func startLoading() {
        guard let url = request.url, let host = url.host,
              let fake = Self.lock.withLock({ Self.fakes[host]?.fake }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }

        let body = request.httpBody ?? request.httpBodyStream.map(Self.drain)
        let response = fake.handle(
            method: request.httpMethod ?? "GET", url: url,
            headers: request.allHTTPHeaderFields ?? [:], body: body
        )

        let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1",
                                   headerFields: response.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        if let data = response.body { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
