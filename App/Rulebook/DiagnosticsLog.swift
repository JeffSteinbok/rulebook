import Foundation

/// A bounded, in-memory log the user can hand back with a bug report.
///
/// Everything a tester can currently tell you about a failure is prose. The
/// app surfaces `error.localizedDescription`, and MSAL flattens most of its
/// failures into MSALErrorInternal (-50000), whose description is empty — so
/// "it didn't connect" is all that survives. The real reason only appears in
/// MSAL's own log callback, which went to `NSLog`: the system log, which no
/// tester can retrieve without a Mac and Console.app.
///
/// This keeps the last few hundred lines somewhere the app can show and share.
/// In memory only, never written to disk: nothing to purge, nothing to declare
/// in a privacy label, and it dies with the process.
final class DiagnosticsLog: @unchecked Sendable {
    static let shared = DiagnosticsLog()

    /// MSAL calls its log callback from its own queues, so access is
    /// serialised rather than actor-isolated — the callback is not async and
    /// cannot await a hop.
    private let queue = DispatchQueue(label: "net.steinbok.Rulebook.diagnostics")
    private var entries: [String] = []

    /// Enough to cover a full interactive sign-in, which is the longest thing
    /// worth capturing. Older lines fall off the front.
    private let limit = 500

    func append(_ message: String) {
        let line = "\(Date.now.formatted(.iso8601)) \(Self.redacted(message))"
        queue.async {
            self.entries.append(line)
            if self.entries.count > self.limit {
                self.entries.removeFirst(self.entries.count - self.limit)
            }
        }
    }

    /// The log is shared by the person who owns it, but it is still the one
    /// path off the device. Microsoft's error text often carries the sign-in
    /// address (and MSAL's own masking misses it there), so addresses are
    /// replaced before anything is stored.
    static func redacted(_ message: String) -> String {
        message.replacingOccurrences(
            of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
            with: "<address>",
            options: .regularExpression
        )
    }

    func clear() {
        queue.async { self.entries.removeAll() }
    }

    var isEmpty: Bool { queue.sync { entries.isEmpty } }

    /// The log on its own is not much use without knowing what produced it,
    /// so the build and device travel with it.
    func report() -> String {
        let body = queue.sync { entries.joined(separator: "\n") }
        return """
        Rulebook diagnostics
        Generated: \(Date.now.formatted(.iso8601))
        App: \(Self.appVersion)
        OS: \(Self.osVersion)
        Device: \(Self.deviceModel)

        \(body.isEmpty ? "(no entries)" : body)
        """
    }

    // MARK: - Environment

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    /// `ProcessInfo`, not `UIDevice.current.systemVersion`: `UIDevice` is main
    /// actor-isolated, and this is read from whatever queue is sharing the log.
    private static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "iOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// The hardware identifier ("iPhone16,2"), not the marketing name — Apple
    /// ships no API for the latter, and the identifier is what crash reports
    /// and Apple's own documentation are indexed by.
    private static var deviceModel: String {
        var info = utsname()
        uname(&info)
        return Mirror(reflecting: info.machine).children.reduce(into: "") { result, element in
            guard let byte = element.value as? Int8, byte != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(byte))))
        }
    }
}
