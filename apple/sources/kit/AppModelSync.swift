import Foundation
import OpenAPIRuntime
import RabbitEarsAPI

/// The replica of the signed-in server, the queue of this device's actions
/// on it and the engine that keeps it in step, from sign-in to sign-out.
@MainActor
public final class SyncSession {
    public let replica: Replica
    public let queue: ActionQueue
    public let engine: SyncEngine
    /// The replica kept lacked what this build reads and was dropped at open.
    let outdated: Bool
    /// The launch a failed library update holds, for `retryLibraryUpdate`.
    var heldLaunch: (endpoint: ServerEndpoint, client: Client)?
    private let live: LiveFeed
    private var following: Task<Void, Never>?
    private var followers = 0
    private var pump: Task<Void, Never>?
    private var toldUnsupported = false

    /// The longest a sign-out waits for the queue to reach the server.
    static let lastFlush = Duration.seconds(3)

    private struct Unsent: Error {}

    /// Opens what `directory` keeps, and catches up off the way in. Each
    /// commit to the replica moves `live`'s count for it.
    init(
        directory: URL, endpoint: ServerEndpoint, token: String, transport: (any ClientTransport)?, live: LiveFeed,
        signOut: @escaping @MainActor () async -> Void
    ) {
        let replica = Replica(directory: directory)
        // One that does not open stays empty, and every read finds nothing until a snapshot.
        try? replica.open()
        outdated = replica.dropOutdated()
        let wakes = Wakes()
        let queue = ActionQueue(
            replica: replica, client: endpoint.client(token: token, transport: transport),
            notice: { operation, _ in Task { @MainActor in live.say(Self.rejected(operation)) } },
            afterFlush: { Task { @MainActor in wakes.engine?.wake() } })
        engine = SyncEngine(
            replica: replica, endpoint: endpoint, token: token, transport: transport,
            flush: {
                // No replica yet to send against: the snapshot comes first.
                guard !replica.isEmpty else { return }
                switch await queue.flush() {
                case .done: return
                // The engine signs out on it, as on a refused read.
                case .refused(let error): throw error
                case .offline, .unsupported: throw Unsent()
                }
            }, signOut: signOut)
        wakes.engine = engine
        self.replica = replica
        self.queue = queue
        self.live = live
        pump = Task { for await group in replica.changes { live.changed(group) } }
        if replica.lostActions { live.say("Some changes made offline were lost.") }
        Task { [engine] in
            try? await engine.catchUp()
            self.check()
        }
    }

    /// Starts the one sync loop for the first view following; `unfollow` ends it with the last.
    func follow() {
        followers += 1
        guard following == nil else { return }
        following = Task {
            await engine.follow()
            check()
            // Refused or unsupported: the next view to follow tries again.
            if !Task.isCancelled { following = nil }
        }
    }

    func unfollow() {
        followers -= 1
        guard followers == 0 else { return }
        following?.cancel()
        following = nil
    }

    /// Stops syncing and closes the replica, keeping its files for the next
    /// session. `wipe`, for a replica no longer this device's, first gives
    /// the queue `lastFlush` to reach the server, then deletes the replica
    /// and whatever is still unsent.
    func end(wipe: Bool) async {
        following?.cancel()
        following = nil
        pump?.cancel()
        guard wipe else { return replica.close() }
        if !replica.isEmpty {
            let (done, finished) = AsyncStream.makeStream(of: Void.self)
            let flushing = Task { [queue] in
                _ = await queue.flush()
                finished.finish()
            }
            let limit = Task {
                try? await Task.sleep(for: Self.lastFlush)
                finished.finish()
            }
            for await _ in done {}
            flushing.cancel()
            limit.cancel()
        }
        try? replica.wipe()
    }

    private func check() {
        guard engine.unsupported, !toldUnsupported else { return }
        toldUnsupported = true
        live.say("Update Rabbit Ears to keep this device in sync.")
    }

    /// The line a user reads when the server refused one of their changes.
    static func rejected(_ operation: String) -> String {
        let named: [(String, String)] = [
            ("Share", "a playlist share"), ("Playlist", "a playlist"), ("Collection", "a collection"),
            ("Station", "a station"), ("WatchState", "watch progress"), ("Kids", "a kids' content setting"),
            ("recordPlay", "a play"), ("Preferences", "profile settings"), ("llowItem", "an allow list"),
            ("Favorite", "a favorite"),
        ]
        return "Couldn't save \(named.first { operation.contains($0.0) }?.1 ?? "a change")."
    }
}

extension AppModel {
    /// The client of a session, and its sync opened. A `fresh` sign-in, as
    /// to another server or household, starts from no replica.
    func connect(_ endpoint: ServerEndpoint, token: String, fresh: Bool) async -> Client {
        end(wipe: fresh)
        await ending?.value
        if fresh { try? Replica(directory: replicaDirectory).wipe() }
        sync = SyncSession(
            directory: replicaDirectory, endpoint: endpoint, token: token, transport: transport, live: live
        ) { [weak self] in await self?.signOut() }
        let changes = live.changes()
        sections = Task { [weak self] in
            for await group in changes where group == .library {
                await self?.loadLibrarySections()
                await self?.downloads?.loadLibraries()
            }
        }
        let client = endpoint.client(token: token, transport: transport, offline: downloads) { [weak self] in
            self?.lockedOut()
        }
        let plays = sync.map { session in
            let queue = session.queue
            // A position is saved at the queue's own instant, which is the report's.
            return LocalPlays(
                progress: { profile, item, edition, positionMs, watched, _ in
                    try? await queue.putWatchState(
                        watched, positionMs: positionMs, edition: edition, item: item, as: profile)
                },
                finished: { profile, item, edition, at in
                    try? await queue.recordPlay(item: item, edition: edition, as: profile, at: at)
                })
        }
        downloads?.connect(client: client, endpoint: endpoint, token: token, replica: sync?.replica, plays: plays)
        return client
    }

    public enum LibraryUpdate: Equatable, Sendable {
        /// A snapshot is on its way in place of a replica this build cannot read.
        case updating
        /// The server can't be reached to send one; the launch waits for `retryLibraryUpdate`.
        case unreachable
    }

    /// A launch whose replica was dropped at open as outdated waits for its
    /// snapshot before any view reads the replica. A refusal, as a device
    /// locked at Who's watching, or a server that no longer syncs with this
    /// build lets it go on with no replica, as after a sign-in. False holds
    /// the launch while the server can't be reached.
    func updateLibrary(_ endpoint: ServerEndpoint, _ client: Client) async -> Bool {
        guard let sync, sync.outdated, sync.replica.isEmpty else { return true }
        libraryUpdate = .updating
        do {
            try await sync.engine.catchUp()
        } catch let error where sync.replica.isEmpty && (APIError.from(error).map { $0.status >= 500 } ?? true) {
            libraryUpdate = .unreachable
            sync.heldLaunch = (endpoint, client)
            return false
        } catch {}
        libraryUpdate = nil
        return true
    }

    /// Tries the update a launch is held on again, then goes on with the launch.
    public func retryLibraryUpdate() async {
        guard let held = sync?.heldLaunch else { return }
        sync?.heldLaunch = nil
        libraryUpdate = nil
        await launch(held.endpoint, held.client)
    }

    /// Ends the open session, if any, in the background, as `SyncSession.end`.
    func end(wipe: Bool) {
        guard let sync else { return }
        self.sync = nil
        libraryUpdate = nil
        sections?.cancel()
        let before = ending
        ending = Task {
            await before?.value
            await sync.end(wipe: wipe)
        }
    }

    /// The address the replica names for a key's art as the active profile is shown it.
    func artAddress(_ key: ArtKey) async -> String? {
        guard let profile = activeProfile?.id, let replica = sync?.replica else { return nil }
        return (try? await replica.read { try key.address(for: profile, $0) }) ?? nil
    }

    static func keptMe(_ endpoint: ServerEndpoint) -> String { "me \(endpoint.baseURL.absoluteString)" }
}

/// The engine the queue wakes after a flush, set once both exist.
@MainActor
private final class Wakes {
    weak var engine: SyncEngine?
}
