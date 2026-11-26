import Foundation
import Observation
import RabbitEarsAPI

public typealias LiveEvent = Components.Schemas.Event
public typealias PlaybackSession = Components.Schemas.PlaybackSession

/// What the server says has changed while this device is signed in and in
/// view. An event names a kind and ids; what changed is read again through
/// the ordinary operations.
@MainActor
@Observable
public final class LiveFeed {
    /// Each counts the changes to what it names; a view showing it loads again when its count moves.
    public private(set) var watched = 0
    public private(set) var stations = 0
    public private(set) var playlists = 0
    public private(set) var together = 0
    /// Offers or memberships of the device's household.
    public private(set) var household = 0
    /// A line shown for a few seconds over whatever is up, as "Moved to Living Room".
    public private(set) var notice: String?

    /// The longest wait between two tries of a failing poll.
    static let longestWait = Duration.seconds(30)
    /// The kinds followed besides the first five, which the server sends only to a client that names them.
    static let kinds: [Components.Schemas.EventKind] = [.library, .household]
    @ObservationIgnored private var listeners: [UUID: AsyncStream<[LiveEvent]>.Continuation] = [:]
    @ObservationIgnored private var followed = false
    @ObservationIgnored private var noticeEnds: Task<Void, Never>?

    /// Its answers changed by the server are told as an empty batch.
    let cache: ResponseCache?

    public init(cache: ResponseCache? = nil) {
        self.cache = cache
        cache?.onChange { [weak self] in Task { @MainActor in self?.tell([]) } }
    }

    /// Runs `reload` with every kept answer asked of the server first, and
    /// returns once it has applied the new data. It runs on its own task, so
    /// a pull that the system cancels, as a view redrawing under it, does not
    /// cancel the requests half-way and leave the old data.
    public func pull(_ reload: @escaping @MainActor () async -> Void) async {
        cache?.expire()
        await Task { await reload() }.value
    }

    public func say(_ text: String) {
        notice = text
        noticeEnds?.cancel()
        noticeEnds = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { notice = nil }
        }
    }

    /// Every batch from now on, for what acts on single events. An empty batch says to load everything again.
    public func events() -> AsyncStream<[LiveEvent]> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: [LiveEvent].self)
        listeners[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.listeners[id] = nil } }
        return stream
    }

    func tell(_ batch: [LiveEvent]) {
        let kinds = Set(batch.map(\.kind))
        if batch.isEmpty || kinds.contains(.watchState) || kinds.contains(.playback) { watched += 1 }
        if batch.isEmpty || kinds.contains(.station) { stations += 1 }
        if batch.isEmpty || kinds.contains(.playlist) { playlists += 1 }
        if batch.isEmpty || kinds.contains(.watchTogether) { together += 1 }
        if batch.isEmpty || kinds.contains(.household) { household += 1 }
        for listener in listeners.values { listener.yield(batch) }
    }

    /// Follows the stream until cancelled, as while signed in and in view.
    /// A failed poll is tried again after a growing wait; a server without
    /// the stream, or a device signed out or locked, is not asked again.
    /// Following again, as on return from the background, first loads
    /// everything once. True says the server no longer knows this device,
    /// as when its account was deleted on another.
    @discardableResult
    public func follow(
        _ client: Client, sleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) async -> Bool {
        if followed { tell([]) }
        followed = true
        var cursor: String?
        var wait = Duration.seconds(1)
        while !Task.isCancelled {
            do {
                let page = try await client.listEvents(query: .init(after: cursor, kinds: Self.kinds)).ok.body.json
                if page.resync { tell([]) } else if !page.events.isEmpty { tell(page.events) }
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
    /// Follows the server's events while this device is in view, keeping
    /// the catalog's watch state current. Runs until cancelled, or until the
    /// server says it has no events for this device; one it no longer knows
    /// is signed out here.
    public func followLive(_ catalog: CatalogModel?, inView: Bool) async {
        guard inView, let client else { return }
        // Listening before following hears the reload a follow again starts with.
        let events = live.events()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { if await self.live.follow(client) { await self.signOut() } }
            group.addTask {
                for await batch in events {
                    await catalog?.heard(batch)
                    // A scan may add or empty a kind of library; a household event may carry a changed profile.
                    if batch.isEmpty || batch.contains(where: { $0.kind == .library }) {
                        await self.loadLibrarySections()
                    }
                    if batch.isEmpty || batch.contains(where: { $0.kind == .household }) { await self.reload() }
                }
            }
            await group.next()
            group.cancelAll()
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

    public func follow(_ live: LiveFeed) async {
        for await batch in live.events() { await heard(batch) }
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
