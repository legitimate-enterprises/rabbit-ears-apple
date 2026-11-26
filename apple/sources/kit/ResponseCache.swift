import CryptoKit
import Foundation
import HTTPTypes
import OpenAPIRuntime
import RabbitEarsAPI
import Synchronization

/// The server's answers to this device's reads, kept on disk by active
/// profile and request, which every model reads through. A read is
/// answered at once from what is kept, of any age, while the server is
/// asked behind it; an answer the server changed or refused is taken, and
/// views are told to read again. A write the server answered has the next
/// read of each kept answer wait on the server first. What is kept stands
/// in while the server cannot be reached or is failing, ahead of the
/// downloads store's answer from only what is downloaded.
public final class ResponseCache: Sendable {
    /// Every server's and profile's kept answers.
    public static var defaultDirectory: URL { URL.cachesDirectory.appending(path: "catalog") }

    let directory: URL
    private let state: Mutex<State>

    private struct State {
        /// The profile the server answers as; nil, as while locked, keeps and answers nothing.
        var profile: Int64?
        /// An answer kept before this is asked for first.
        var expiredBefore = Date.distantPast
        /// Keys the server is being asked for behind a read, one request each at most.
        var refreshing: Set<String> = []
        /// Keys a refresh changed, answered once more without asking, so a read on the signal asks nothing.
        var refreshed: Set<String> = []
        /// Whether the refreshes in flight have changed anything yet.
        var changed = false
        var signal: (@Sendable () -> Void)?
    }

    struct Kept: Codable {
        let at: Date
        let body: Data
    }

    /// How a read with an answer kept goes.
    enum Use { case askFirst, kept, keptAndRefresh }

    public init(directory: URL = ResponseCache.defaultDirectory) {
        self.directory = directory
        state = Mutex(State())
    }

    public func expire() {
        let now = Date()
        state.withLock { $0.expiredBefore = now }
    }

    /// `signal` runs once the refreshes in flight are all done and any
    /// changed what was kept, for views to read again.
    func onChange(_ signal: @escaping @Sendable () -> Void) {
        state.withLock { $0.signal = signal }
    }

    /// Signed out: nothing kept stays, and nothing is kept until a profile is active again.
    public func clear() {
        state.withLock {
            $0.profile = nil
            $0.refreshed = []
            try? FileManager.default.removeItem(at: directory)
        }
    }

    var profile: Int64? {
        get { state.withLock { $0.profile } }
        set { state.withLock { $0.profile = newValue } }
    }

    func read(_ key: String) -> Kept? {
        (try? Data(contentsOf: file(key))).flatMap { try? PropertyListDecoder().decode(Kept.self, from: $0) }
    }

    /// `.keptAndRefresh` counts the key as refreshing until `refreshed(_:changed:)`.
    func use(_ kept: Kept, for key: String) -> Use {
        state.withLock {
            if kept.at < $0.expiredBefore { return .askFirst }
            if $0.refreshed.remove(key) != nil || $0.refreshing.contains(key) { return .kept }
            $0.refreshing.insert(key)
            return .keptAndRefresh
        }
    }

    /// Ends a key's refresh; the last one in flight signals for them all.
    func refreshed(_ key: String, changed: Bool) {
        let signal: (@Sendable () -> Void)? = state.withLock {
            $0.refreshing.remove(key)
            $0.changed = $0.changed || changed
            guard $0.refreshing.isEmpty, $0.changed else { return nil }
            $0.changed = false
            return $0.signal
        }
        signal?()
    }

    /// Best effort, and only while the profile asking is still active, so
    /// an answer arriving after a switch or a sign-out is dropped. True when
    /// kept; `refreshed` marks it answered once more without asking.
    /// shortcut: nothing evicts a kept answer short of sign-out or the
    /// system clearing Caches; prune by age if the folder grows large.
    @discardableResult
    func keep(_ kept: Kept, for key: String, profile: Int64, refreshed: Bool = false) -> Bool {
        guard let data = try? PropertyListEncoder().encode(kept) else { return false }
        return state.withLock {
            guard $0.profile == profile else { return false }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard (try? data.write(to: file(key), options: .atomic)) != nil else { return false }
            if refreshed { $0.refreshed.insert(key) }
            return true
        }
    }

    /// True when the profile asking is still active, so its views read again.
    func drop(_ key: String, profile: Int64) -> Bool {
        state.withLock {
            guard $0.profile == profile else { return false }
            try? FileManager.default.removeItem(at: file(key))
            return true
        }
    }

    /// The server's last Me as this device has it, for a launch to open
    /// with before the server answers; kept apart from any profile's answers.
    func me(for server: URL) -> Components.Schemas.Me? {
        read("me \(server.absoluteString)").flatMap {
            try? DownloadStore.decoder.decode(Components.Schemas.Me.self, from: $0.body)
        }
    }

    func keep(me: Components.Schemas.Me, for server: URL) {
        guard let body = try? DownloadStore.encoder.encode(me),
            let data = try? PropertyListEncoder().encode(Kept(at: Date(), body: body))
        else { return }
        state.withLock { _ in
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: file("me \(server.absoluteString)"), options: .atomic)
        }
    }

    private func file(_ key: String) -> URL {
        directory.appending(path: SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined())
    }
}

/// Reads through the cache, and notes from Me, locks and unlocks which
/// profile the server answers as. Without a cache it only passes calls on.
struct CacheMiddleware: ClientMiddleware {
    let cache: ResponseCache?
    let downloads: DownloadStore?
    /// The rest of the client's chain, which a refresh behind a read goes
    /// through after the reader has its answer.
    let behind: Chain

    /// Reads never kept: what something waits on to change or what changes
    /// with the time, Me, which names the active profile, a link's token,
    /// and the watch state and up next the downloads store answers offline
    /// from this device's own plays.
    static let asked: Set<String> = [
        "getMe", "listEvents", "getWatchState", "getUpNext", "listPlaybackSessions", "getPlaybackSession",
        "listWatchTogethers", "getWatchTogether", "listStations", "getStation", "listStationSchedule",
        "listDownloads", "getDownload", "getAccountDeletion", "pollDeviceLink",
    ]

    /// Writes that leave every kept answer as it was: the player's periodic
    /// reports, whose effect on watch state comes as a live event, the
    /// questions asked by POST, and a lock or unlock, as each profile's
    /// answers are kept apart.
    static let unmarking: Set<String> = [
        "reportPlaybackPosition", "reportPlaybackEvent", "reportPlaybackThroughput", "updatePlaybackNetwork",
        "updatePlaybackDisplay", "updatePlaybackAudioRoute", "checkPlayability", "resolveDownloads",
        "startLocalCheck", "lockDevice", "unlockProfile",
    ]

    func intercept(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let call = LocalCall(operation: operationID, path: request.path ?? "", body: nil)
        guard let cache, let profile = cache.profile, request.method == .get, !Self.asked.contains(operationID)
        else {
            guard let cache else { return try await next(request, body, baseURL) }
            if request.method != .get { return try await write(call, cache) { try await next(request, body, baseURL) } }
            return try await note(call, cache) { try await next(request, body, baseURL) }
        }
        let slot = Slot(
            cache: cache, key: "\(profile) \(baseURL.absoluteString)\(request.path ?? "")", profile: profile)
        let kept = cache.read(slot.key)
        if let kept, case let use = cache.use(kept, for: slot.key), use != .askFirst {
            if use == .keptAndRefresh {
                let behind = behind
                Task { await refresh(slot, kept) { try await behind.send(request, nil, baseURL, operationID) } }
            }
            return await answer(kept, call)
        }
        return try await read(call, slot, kept) { try await next(request, body, baseURL) }
    }

    /// Where one read's answer is kept: under the profile that asked.
    private struct Slot {
        let cache: ResponseCache
        let key: String
        let profile: Int64
    }

    /// The server's answer, kept when it is a successful read; the kept
    /// one when the server is down or the downloads store answered in its
    /// place.
    private func read(
        _ call: LocalCall, _ slot: Slot, _ kept: ResponseCache.Kept?,
        _ send: () async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let sent = Date()
        let response: HTTPResponse
        let body: HTTPBody?
        do {
            (response, body) = try await send()
        } catch {
            guard let kept, Self.down(error) else { throw error }
            return await answer(kept, call)
        }
        if response.headerFields[OfflineMiddleware.answeredHere] != nil {
            return if let kept { await answer(kept, call) } else { (response, body) }
        }
        guard Self.keeps(response) else { return (response, body) }
        let data = try await Self.collect(body)
        slot.cache.keep(.init(at: sent, body: data), for: slot.key, profile: slot.profile)
        return (response, HTTPBody(data))
    }

    /// Takes a changed answer, or drops the kept one for anything else the
    /// server answers; either has views read again. A server that is down,
    /// or the downloads store answering, leaves what is kept.
    private func refresh(
        _ slot: Slot, _ kept: ResponseCache.Kept, _ send: () async throws -> (HTTPResponse, HTTPBody?)
    ) async {
        var changed = false
        defer { slot.cache.refreshed(slot.key, changed: changed) }
        let sent = Date()
        do {
            let (response, body) = try await send()
            guard response.headerFields[OfflineMiddleware.answeredHere] == nil else { return }
            guard Self.keeps(response) else {
                changed = slot.cache.drop(slot.key, profile: slot.profile)
                return
            }
            let data = try await Self.collect(body)
            changed =
                data != kept.body
                && slot.cache.keep(.init(at: sent, body: data), for: slot.key, profile: slot.profile, refreshed: true)
        } catch {
            if APIError.from(error) != nil, !Self.down(error) {
                changed = slot.cache.drop(slot.key, profile: slot.profile)
            }
        }
    }

    /// Me names the profile the server answers as, or none while locked.
    private func note(
        _ call: LocalCall, _ cache: ResponseCache, _ send: () async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let (response, body) = try await send()
        guard call.operation == "getMe", response.status == .ok else { return (response, body) }
        let data = try await Self.collect(body)
        let me = try? DownloadStore.decoder.decode(Components.Schemas.Me.self, from: data)
        cache.profile = me?.locked == true ? nil : me?.activeProfileId
        return (response, HTTPBody(data))
    }

    /// A write the server answered, with anything, has the next read of
    /// everything kept ask first; a lock or unlock keeps nothing until it
    /// says which profile is active.
    private func write(
        _ call: LocalCall, _ cache: ResponseCache, _ send: () async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let marks = !Self.unmarking.contains(call.operation)
        let locks = call.operation == "lockDevice" || call.operation == "unlockProfile"
        if locks { cache.profile = nil }
        let response: HTTPResponse
        let body: HTTPBody?
        do {
            (response, body) = try await send()
        } catch {
            if marks, APIError.from(error) != nil { cache.expire() }
            throw error
        }
        if marks, response.headerFields[OfflineMiddleware.answeredHere] == nil { cache.expire() }
        if call.operation == "unlockProfile", (200..<300).contains(response.status.code) {
            cache.profile = call.id(after: "profiles")
        }
        return (response, body)
    }

    private func answer(_ kept: ResponseCache.Kept, _ call: LocalCall) async -> (HTTPResponse, HTTPBody?) {
        let body = await downloads?.withUnsynced(call, kept.body) ?? kept.body
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "application/json"
        return (response, HTTPBody(body))
    }

    /// Unreachable, or answering only that it is failing, as behind a proxy.
    private static func down(_ error: any Error) -> Bool {
        (APIError.from(error)?.status ?? 0) >= 500 || OfflineMiddleware.unreachable(error)
    }

    private static func keeps(_ response: HTTPResponse) -> Bool {
        response.status == .ok && response.headerFields[.contentType]?.hasPrefix("application/json") == true
    }

    private static func collect(_ body: HTTPBody?) async throws -> Data {
        guard let body else { return Data() }
        return try await Data(collecting: body, upTo: .max)
    }
}

/// Middlewares and a transport run in order, as the client runs them.
struct Chain: Sendable {
    let middlewares: [any ClientMiddleware]
    let transport: any ClientTransport

    func send(
        _ request: HTTPRequest, _ body: HTTPBody?, _ baseURL: URL, _ operationID: String, from index: Int = 0
    ) async throws -> (HTTPResponse, HTTPBody?) {
        guard middlewares.indices.contains(index) else {
            return try await transport.send(request, body: body, baseURL: baseURL, operationID: operationID)
        }
        return try await middlewares[index].intercept(
            request, body: body, baseURL: baseURL, operationID: operationID
        ) { try await send($0, $1, $2, operationID, from: index + 1) }
    }
}
