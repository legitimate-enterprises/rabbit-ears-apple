import Foundation
import Observation
import RabbitEarsAPI

public typealias LiveEvent = Components.Schemas.Event
public typealias PlaybackSession = Components.Schemas.PlaybackSession

/// What has changed while this device is signed in: the replica's commits,
/// counted by group, and the server's player events while a player is open.
@MainActor
@Observable
public final class LiveFeed {
    /// Each counts the replica's commits to what it names; a view showing it loads again when its count moves.
    public private(set) var watched = 0
    public private(set) var stations = 0
    public private(set) var playlists = 0
    /// Profiles, offers or memberships of the device's household.
    public private(set) var household = 0
    /// Libraries and everything in them.
    public private(set) var library = 0
    /// A line shown for a few seconds over whatever is up, as "Moved to Living Room".
    public private(set) var notice: String?

    /// The longest wait between two tries of a failing poll.
    static let longestWait = Duration.seconds(30)
    @ObservationIgnored private var listeners: [UUID: AsyncStream<[LiveEvent]>.Continuation] = [:]
    @ObservationIgnored private var watchers: [UUID: AsyncStream<Replica.Group>.Continuation] = [:]
    @ObservationIgnored private var noticeEnds: Task<Void, Never>?

    public init() {}

    public func say(_ text: String) {
        notice = text
        noticeEnds?.cancel()
        noticeEnds = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { notice = nil }
        }
    }

    /// The replica committed a change to `group`.
    func changed(_ group: Replica.Group) {
        switch group {
        case .library: library += 1
        case .watched: watched += 1
        case .playlists: playlists += 1
        case .stations: stations += 1
        case .household: household += 1
        }
        for watcher in watchers.values { watcher.yield(group) }
    }

    /// Every group the replica commits a change to from now on.
    public func changes() -> AsyncStream<Replica.Group> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: Replica.Group.self)
        watchers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.watchers[id] = nil } }
        return stream
    }

    /// Every batch of player events from now on.
    public func events() -> AsyncStream<[LiveEvent]> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: [LiveEvent].self)
        listeners[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.listeners[id] = nil } }
        return stream
    }

    func tell(_ batch: [LiveEvent]) {
        for listener in listeners.values { listener.yield(batch) }
    }

    /// Follows the server's player events until cancelled, as while a
    /// player is open; the catalog follows the replica instead. A failed
    /// poll is tried again after a growing wait; a server without the
    /// stream, or a device signed out or locked, is not asked again. True
    /// says the server no longer knows this device.
    @discardableResult
    public func follow(
        _ client: Client, sleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) async -> Bool {
        var cursor: String?
        var wait = Duration.seconds(1)
        while !Task.isCancelled {
            do {
                let page = try await client.listEvents(query: .init(after: cursor)).ok.body.json
                if !page.events.isEmpty { tell(page.events) }
                cursor = page.cursor
                wait = .seconds(1)
            } catch {
                if Task.isCancelled { return false }
                if let api = APIError.from(error), api.status < 500 { return api.code == .unauthorized }
                await sleep(wait)
                wait = min(wait * 2, Self.longestWait)
            }
        }
        return false
    }
}

extension AppModel {
    /// Keeps the replica in step with the server while this device is in
    /// view, and the catalog with the replica. Every view following shares
    /// the session's one sync loop, which ends with the last of them.
    public func followLive(_ catalog: CatalogModel?, inView: Bool) async {
        guard inView, let sync else { return }
        let changes = live.changes()
        sync.follow()
        defer { sync.unfollow() }
        // The first snapshot may have landed between the catalog's first read and listening.
        if catalog?.loaded == false { await catalog?.load() }
        for await group in changes {
            await catalog?.heard(group)
            // A profile changed, as its Hide setting or its name.
            if group == .household { await reload() }
        }
    }
}

/// A title still playing on another device of the profile is asked about
/// before it plays here: Move here, Watch together or Cancel.
@MainActor
public enum Handoff {
    /// The profile's session on the title on another device, playing now.
    /// Nil when there is none, and for a request that says where to start
    /// or already watches together, and when the server has not answered
    /// within `limit`: a late answer is dropped, so the title plays unasked.
    public static func elsewhere(
        _ request: PlayRequest, client: Client, within limit: Duration = .seconds(3)
    ) async -> PlaybackSession? {
        guard request.positionMs == nil, request.together == nil else { return nil }
        let itemId = request.item.id
        return await withTaskGroup(of: PlaybackSession?.self) { group in
            group.addTask {
                let page = try? await client.listPlaybackSessions(query: .init(itemId: itemId)).ok.body.json
                return page?.items.first { !$0.thisDevice }
            }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            // The sleep ends first without an answer, or the check does; the loser is cancelled.
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// "Playing on Living Room at 41:12".
    public static func title(_ there: PlaybackSession) -> String {
        "Playing on \(there.deviceName) at \(Format.clock(seconds: Double(there.positionMs) / 1000))"
    }

    /// Move here: ends the session there; the answer plays here where it was.
    public static func move(
        _ there: PlaybackSession, _ request: PlayRequest, client: Client
    ) async throws -> PlayRequest {
        let moved = try await client.movePlaybackSession(path: .init(sessionId: there.id)).ok.body.json
        return PlayRequest(
            item: request.item, audioTrackId: request.audioTrackId, editionId: request.editionId,
            positionMs: moved.positionMs, queue: request.queue)
    }

    /// Watch together: opens one from the session there, which that device
    /// joins by itself; the answer plays here in it.
    public static func together(
        _ there: PlaybackSession, _ request: PlayRequest, client: Client, profileId: Int64
    ) async throws -> PlayRequest {
        let model = WatchTogetherModel(client: client, profileId: profileId, itemId: request.item.id)
        try await model.open(from: there.id)
        return PlayRequest(item: request.item, positionMs: there.positionMs, together: model)
    }
}

/// What the live events ask of an open player: to close when another device
/// took its session with Move here, and to start over in the Watch together
/// another device opened from its session.
@MainActor
@Observable
public final class PlayerHandoff {
    /// The device that took the session; the player closes and says so.
    public private(set) var movedTo: String?
    /// The Watch together this player was asked into, joined.
    public private(set) var asked: WatchTogetherModel?

    private let player: PlayerModel
    private let client: Client
    private let profileId: Int64
    private let itemId: Int64

    public init(player: PlayerModel, client: Client, profileId: Int64, itemId: Int64) {
        self.player = player
        self.client = client
        self.profileId = profileId
        self.itemId = itemId
    }

    /// Follows the server's player events while the player is open.
    public func follow(_ live: LiveFeed) async {
        let events = live.events()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [client] in await live.follow(client) }
            group.addTask { for await batch in events { await self.heard(batch) } }
            await group.next()
            group.cancelAll()
        }
    }

    public func heard(_ batch: [LiveEvent]) async {
        guard player.station == nil else { return }
        for event in batch {
            guard let session = player.stream?.sessionId, event.sessionId == session else { continue }
            if event.kind == .playback, event.change == "moved" {
                let there = try? await client.getPlaybackSession(path: .init(sessionId: session)).ok.body.json
                player.taken()
                movedTo = there?.movedToDeviceName ?? "another device"
            } else if event.kind == .watchTogether, event.change == "opened", let id = event.watchTogetherId {
                let model = WatchTogetherModel(client: client, profileId: profileId, itemId: itemId)
                if await model.join(id, playingAt: player.output.positionMs) { asked = model }
            }
        }
    }
}
