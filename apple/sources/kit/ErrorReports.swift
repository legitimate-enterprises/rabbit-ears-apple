import Foundation
import OpenAPIRuntime
import RabbitEarsAPI
import Synchronization

/// reportClientErrors' entries as the device makes them: scrubbed of what a
/// client must not send, then cut to the spec's lengths in Unicode code
/// points, so the server never refuses one as invalid.
enum ErrorReports {
    static let messageLimit = 1000
    static let contextLimit = 100
    static let detailLimit = 4000

    /// The app's M.m.N, as its bundle states it.
    static let appVersion = bounded(
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0", 64)

    /// The platform and its version, as "iOS 27.1".
    static let osVersion: String = {
        #if os(macOS)
            let platform = "macOS"
        #elseif os(tvOS)
            let platform = "tvOS"
        #else
            let platform = "iOS"
        #endif
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let patch = version.patchVersion > 0 ? ".\(version.patchVersion)" : ""
        return "\(platform) \(version.majorVersion).\(version.minorVersion)\(patch)"
    }()

    typealias Entry = Components.Schemas.ClientError

    static func entry(at: Date, message: String, context: String, detail: String? = nil) -> Entry {
        let message = cut(message, messageLimit)
        let context = cut(context, contextLimit)
        let detail = detail.map { cut($0, detailLimit) }
        return .init(
            id: UID.new(), at: at,
            message: message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Unknown error." : message,
            context: context.isEmpty ? "app" : context, detail: detail?.isEmpty == false ? detail : nil)
    }

    /// At most `limit` Unicode code points of `text`, as the server counts length.
    static func bounded(_ text: String, _ limit: Int) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.prefix(limit))
        return String(scalars)
    }

    /// Cut before scrubbing too, so no long text meets the expressions.
    private static func cut(_ text: String, _ limit: Int) -> String {
        bounded(scrubbed(bounded(text, limit * 2)), limit)
    }

    /// `text` with no URL's user-info, query or fragment, no stream or
    /// station key from a media path, no `name=value` secret or bearer
    /// token, and no email address.
    static func scrubbed(_ text: String) -> String {
        text.replacing(#/([A-Za-z][A-Za-z0-9+.\-]*:\/\/)(?:[^\s\/?#@]*@)?([^\s?#"'<>]*)[^\s"'<>]*/#) {
            "\($0.1)\($0.2)"
        }
        .replacing(#/(\/(?:streams|channels)\/)[^\/\s"'?#]+/#) { "\($0.1)[redacted]" }
        .replacing(#/((?:api_?key|access_token|token|password|pin|secret|code|verifier)=)[^&\s"]+/#.ignoresCase()) {
            "\($0.1)[redacted]"
        }
        .replacing(#/(bearer\s+)\S+/#.ignoresCase()) { "\($0.1)[redacted]" }
        .replacing(#/[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}/#, with: "[email]")
    }
}

/// Queues, for reportClientErrors, the errors a signed-in session meets
/// that an admin should see: each context and message once a session, and
/// at most `hourlyLimit` in any hour, well under the server's 100 a device.
/// Until the session has a replica to queue in and a profile to act as,
/// they wait in memory.
final class ErrorReporter: Sendable {
    static let hourlyLimit = 50
    /// reportClientErrors' entries maxItems.
    static let batchLimit = 25

    private struct Open {
        weak var reporter: ErrorReporter?
    }

    /// The signed-in session's; none before sign-in, when nothing is held.
    private static let current = Mutex(Open())

    private struct State {
        var seen: Set<String> = []
        var recent: [Date] = []
        var held: [ErrorReports.Entry] = []
    }

    private let queue: ActionQueue
    private let replica: Replica
    private let acting: @MainActor @Sendable () -> UID?
    private let now: @Sendable () -> Date
    private let state = Mutex(State())

    init(
        queue: ActionQueue, replica: Replica, acting: @escaping @MainActor @Sendable () -> UID?,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.queue = queue
        self.replica = replica
        self.acting = acting
        self.now = now
    }

    /// Makes this the reporter `report` and `AppError.from` reach.
    func open() { Self.current.withLock { $0.reporter = self } }

    func close() { Self.current.withLock { if $0.reporter === self { $0.reporter = nil } } }

    /// To the open session's reporter; nothing when signed out.
    static func report(_ message: String, context: String, detail: String? = nil) {
        current.withLock { $0.reporter }?.report(message, context: context, detail: detail)
    }

    /// A failure to decode a response the server gave, which shows the API
    /// drifting from this build, under its operation. False for any other error.
    @discardableResult
    static func reportUndecoded(_ error: any Error, at site: String) -> Bool {
        guard let failure = error as? ClientError, let response = failure.response, APIError.from(error) == nil
        else { return false }
        report(
            String(describing: failure.underlyingError), context: failure.operationID,
            detail: "HTTP \(response.status.code) at \(site)")
        return true
    }

    func report(_ message: String, context: String, detail: String? = nil) {
        let at = now()
        let entry = ErrorReports.entry(at: at, message: message, context: context, detail: detail)
        let taken = state.withLock { state in
            let key = entry.context + "\n" + entry.message
            state.recent.removeAll { at.timeIntervalSince($0) >= 3600 }
            guard state.recent.count < Self.hourlyLimit, state.seen.insert(key).inserted else { return false }
            state.recent.append(at)
            state.held.append(entry)
            return true
        }
        if taken { Task { await send() } }
    }

    /// Queues what is held once there is a replica and a profile to act as.
    func send() async {
        guard state.withLock({ !$0.held.isEmpty }), !replica.isEmpty, let profile = await acting() else { return }
        let held = state.withLock { state in
            defer { state.held = [] }
            return state.held
        }
        for start in stride(from: 0, to: held.count, by: Self.batchLimit) {
            try? await queue.reportClientErrors(
                Array(held[start..<min(start + Self.batchLimit, held.count)]), as: profile)
        }
    }
}

extension ActionQueue {
    static let reportOperation = "reportClientErrors"

    /// reportClientErrors: writes no replica row. A rejection drops it unheard.
    func reportClientErrors(_ entries: [ErrorReports.Entry], as profileId: UID) async throws {
        try await act(
            as: profileId, touching: [],
            call: { client, _ in
                _ = try await client.reportClientErrors(
                    body: .json(
                        .init(
                            appVersion: ErrorReports.appVersion, osVersion: ErrorReports.osVersion, entries: entries)))
            },
            apply: { _, _ in })
    }
}
