import Foundation
import Observation
import RabbitEarsAPI

public typealias WatchTogether = Components.Schemas.WatchTogether

extension AppModel {
    /// Watch together on one title as the active profile, adult or kid: the
    /// server lists a kid only those on titles the kid may see.
    public func watchTogether(itemId: Int64) -> WatchTogetherModel? {
        guard let client, let profile = activeProfile else { return nil }
        return WatchTogetherModel(client: client, profileId: profile.id, itemId: itemId)
    }
}

/// Watch together on one title, from its details screen through the player.
/// The server holds the shared state and answers each change at once to a
/// held poll; its answer always wins. Every play, pause and seek takes effect
/// at one instant on the server's clock, which this model estimates, and the
/// attached player follows it there.
@MainActor
@Observable
public final class WatchTogetherModel {
    /// A playing player this far from the shared position seeks to it.
    public static let driftMs: Int64 = 500
    /// Quick answers sampled for the clock before polls are held.
    static let samples = 3
    /// A held poll answered unchanged after at least this long ran out its hold.
    static let heldAtLeast: TimeInterval = 1
    /// After a correcting seek, the player is left this long to buffer before the next.
    static let settle: TimeInterval = 3

    public let itemId: Int64
    /// The one this profile is in, waiting or joined.
    public private(set) var current: WatchTogether?
    /// Someone else's waiting one on this title, for Join.
    public private(set) var invite: WatchTogether?
    public private(set) var error: String?
    /// Opens the player at a position. Called once when playing turns true
    /// while no player is attached, as for a member still on details.
    @ObservationIgnored public var onStart: ((Int64) -> Void)?
    /// The server's clock less this device's, in milliseconds.
    @ObservationIgnored public private(set) var offsetMs: Int64 = 0

    private let client: Client
    private let profileId: Int64
    private let now: () -> Date
    private var receivedAt: Date
    @ObservationIgnored private weak var output: (any VideoOutput)?
    @ObservationIgnored private var startRequested = false
    @ObservationIgnored private var running = false
    /// Left by this viewer; the server may list one until it notices.
    @ObservationIgnored private var left: Set<Int64> = []
    @ObservationIgnored private var bestRoundTrip = Int64.max
    /// The latest round trip of a request that was not held, reported so the
    /// server leads no further ahead than this device needs.
    @ObservationIgnored private var latestRoundTrip: Int?
    @ObservationIgnored private var sampled = 0
    /// The shared state's change still waiting for its instant.
    @ObservationIgnored private var due: Task<Void, Never>?
    @ObservationIgnored private var settledAt = Date.distantPast

    public init(client: Client, profileId: Int64, itemId: Int64, now: @escaping () -> Date = Date.init) {
        self.client = client
        self.profileId = profileId
        self.itemId = itemId
        self.now = now
        receivedAt = now()
    }

    /// Joined: play, pause and seek go through this model.
    public var inSync: Bool { current?.status == .joined }

    /// The other member, as in "In sync with Heidi"; the profile's own other device by that device's name.
    public var partnerName: String? {
        current?.members.first { $0.accountId != profileId }?.name
            ?? current?.members.first { $0.thisDevice == false }?.deviceName
    }

    /// "Heidi paused", while the other member's pause holds.
    public var pausedNotice: String? {
        guard let current, current.status == .joined, !current.playing, current.pausedById != profileId,
            let name = current.pausedByName
        else { return nil }
        return "\(name) paused"
    }

    /// "Join Heidi · 4:12" while someone else's window is open.
    public func joinLabel(at date: Date) -> String? {
        guard current == nil, let invite, let host = invite.members.first(where: { $0.role == .host }),
            let left = countdown(invite, at: date)
        else { return nil }
        return "Join \(host.accountId == profileId ? host.deviceName : host.name) · \(left)"
    }

    /// "Waiting for someone to join · 4:32" while this profile's window is open.
    public func waitingLabel(at date: Date) -> String? {
        guard let current, current.status == .waiting, let left = countdown(current, at: date) else { return nil }
        return "Waiting for someone to join · \(left)"
    }

    /// The shared position at a moment on this device's clock: as of the
    /// latest change, run on from its instant while playing.
    public func sharedPositionMs(at date: Date) -> Int64 {
        guard let current else { return 0 }
        let since = serverMs(date) - current.effectiveAtMs
        return current.effectivePositionMs + (current.playing ? max(0, since) : 0)
    }

    /// Lists the title until this profile is in one, then samples the clock
    /// and holds a poll for each change while a second loop corrects drift.
    public func run() async {
        // Details and the player may both ask; one loop polls.
        guard !running else { return }
        running = true
        defer { running = false }
        async let corrections: Void = correcting()
        while !Task.isCancelled {
            if current == nil {
                await refresh()
                try? await Task.sleep(for: .seconds(5))
            } else if sampled < Self.samples {
                sampled += 1
                await poll()
            } else {
                let version = current?.version
                let began = now()
                let answered = await poll(held: true)
                // A hold that ran out is asked again at once: a change in the gap would be heard late. A
                // failure, or an answer that came back unchanged and quick, waits.
                if current?.version == version && !(answered && now().timeIntervalSince(began) >= Self.heldAtLeast) {
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
        await corrections
    }

    public func refresh() async {
        guard let page = try? await client.listWatchTogethers(query: .init(itemId: itemId)).ok.body.json else { return }
        let open = page.items.filter { $0.status != .ended && !left.contains($0.id) }
        if let mine = open.first(where: isMember) { receive(mine) }
        receivedAt = now()
        invite = current == nil ? open.first { $0.status == .waiting && !isMember($0) } : nil
    }

    public func open() async {
        await act { try await client.openWatchTogether(body: .json(.init(itemId: itemId))).created.body.json }
    }

    public func join() async {
        guard let invite else { return }
        await act { try await client.joinWatchTogether(path: .init(watchTogetherId: invite.id)).ok.body.json }
    }

    /// Opens one from the session playing on another device of the profile, at that session's position.
    func open(from sessionId: Int64) async throws {
        receive(
            try await client.openWatchTogether(body: .json(.init(itemId: itemId, fromSessionId: sessionId))).created
                .body.json)
    }

    /// Joins the one another device of the profile opened from this device's
    /// session, and plays for both from where this device is.
    func join(_ id: Int64, playingAt positionMs: Int64) async -> Bool {
        do {
            receive(try await client.joinWatchTogether(path: .init(watchTogetherId: id)).ok.body.json)
            receive(
                try await client.setWatchTogetherState(
                    path: .init(watchTogetherId: id), body: .json(.init(playing: true, positionMs: positionMs))
                ).ok.body.json)
            return current != nil
        } catch {
            return false
        }
    }

    /// Ends it for both; this player plays on alone. A failed request still
    /// leaves, since the server ends it once no member polls.
    public func leave() async {
        guard let id = current?.id else { return }
        left.insert(id)
        end()
        _ = try? await client.leaveWatchTogether(path: .init(watchTogetherId: id)).noContent
    }

    /// A quick poll samples the clock; a held one waits for the next change.
    /// Returns whether the server answered.
    @discardableResult
    public func poll(held: Bool = false) async -> Bool {
        guard let id = current?.id else { return false }
        do {
            let sent = now()
            let next = try await client.getWatchTogether(
                path: .init(watchTogetherId: id),
                query: .init(after: held ? current?.version : nil, rttMs: latestRoundTrip)
            ).ok.body.json
            if !held { clock(next, sent: sent) }
            receive(next)
            return true
        } catch {
            // Gone means ended; any other failure waits for the next poll.
            if APIError.from(error)?.status == 404 { end() }
            return false
        }
    }

    /// The player this device shows; it is brought to the shared state at once.
    public func attach(_ output: any VideoOutput) {
        self.output = output
        if let current { follow(current) }
    }

    public func detach() {
        output = nil
        due?.cancel()
    }

    /// Play together: both start at the shared position, each opening its
    /// player if it has none.
    public func playTogether() async { await send(playing: true, positionMs: sharedPositionMs(at: now())) }

    /// Plays for both; this player waits for the instant they start at.
    public func play() async { await send(playing: true, positionMs: position) }

    /// Pauses here at once and for the other at the instant it takes effect.
    public func pause() async {
        let at = position
        output?.pause()
        await send(playing: false, positionMs: at)
    }

    public func seek(toMs ms: Int64) async {
        output?.seek(toMs: ms)
        await send(playing: current?.playing ?? false, positionMs: ms)
    }

    private var position: Int64 { output?.positionMs ?? sharedPositionMs(at: now()) }

    private func send(playing: Bool, positionMs: Int64) async {
        guard let id = current?.id, inSync else { return }
        let sent = now()
        await act {
            let next = try await client.setWatchTogetherState(
                path: .init(watchTogetherId: id), query: .init(rttMs: latestRoundTrip),
                body: .json(.init(playing: playing, positionMs: positionMs))
            ).ok.body.json
            clock(next, sent: sent)
            return next
        }
    }

    private func act(_ request: () async throws -> WatchTogether) async {
        do {
            receive(try await request())
            error = nil
        } catch {
            self.error = AppError.from(error, unauthorized: .signedOut).localizedDescription
        }
    }

    /// Takes the server's clock as of the round trip's midpoint, from the
    /// quickest round trip yet.
    private func clock(_ answer: WatchTogether, sent: Date) {
        let back = now()
        let trip = milliseconds(since: sent, at: back)
        latestRoundTrip = Int(trip)
        guard trip < bestRoundTrip else { return }
        bestRoundTrip = trip
        offsetMs = answer.serverTimeMs - Int64((sent.timeIntervalSince1970 * 1000).rounded()) - trip / 2
    }

    private func serverMs(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) + offsetMs }

    /// An answer older than one already applied is dropped: polls and
    /// actions overlap, and `version` orders them. So is one for a Watch
    /// together this viewer left while the request was in flight.
    private func receive(_ next: WatchTogether) {
        if left.contains(next.id) { return }
        if let current, current.id == next.id, next.version < current.version { return }
        receivedAt = now()
        guard next.status != .ended else { return end() }
        current = next
        invite = nil
        follow(next)
    }

    /// Applies the state at its instant, or at once if that has passed.
    private func follow(_ state: WatchTogether) {
        guard state.status == .joined else { return }
        if !state.playing { startRequested = false }
        guard let output else {
            if state.playing && !startRequested {
                startRequested = true
                onStart?(sharedPositionMs(at: now()))
            }
            return
        }
        due?.cancel()
        due = nil
        let wait = state.effectiveAtMs - serverMs(now())
        guard wait > 0 else { return apply(state, to: output) }
        if state.playing {
            output.play(atMs: state.effectivePositionMs, after: Double(wait) / 1000)
            settledAt = now().addingTimeInterval(Double(wait) / 1000 + Self.settle)
            return
        }
        due = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(wait))
            guard !Task.isCancelled, let self, let output = self.output, let current = self.current,
                current.version == state.version
            else { return }
            self.due = nil
            self.apply(current, to: output)
        }
    }

    private func apply(_ state: WatchTogether, to output: any VideoOutput) {
        if state.playing && output.isPaused { output.play() }
        if !state.playing && !output.isPaused { output.pause() }
        correct(output, force: true)
    }

    /// Never while buffering: the shared position runs on during a seek, so
    /// seeking again then would never let the player catch up.
    private func correct(_ output: any VideoOutput, force: Bool = false) {
        guard let current, current.status == .joined, due == nil, !output.isBuffering else { return }
        if !force && (!current.playing || output.isPaused || now() < settledAt) { return }
        let shared = sharedPositionMs(at: now())
        guard abs(output.positionMs - shared) > Self.driftMs else { return }
        output.seek(toMs: shared)
        settledAt = now().addingTimeInterval(Self.settle)
    }

    private func correcting() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            if let output { correct(output) }
        }
    }

    private func end() {
        current = nil
        startRequested = false
        due?.cancel()
        due = nil
    }

    /// Whether this device takes part: the profile's other device may, in one this device is not in.
    private func isMember(_ together: WatchTogether) -> Bool {
        together.members.contains { $0.accountId == profileId && $0.thisDevice != false }
    }

    /// m:ss of the window left, counted from the server's figure so the
    /// device clock does not matter; nil once it has run out.
    private func countdown(_ together: WatchTogether, at date: Date) -> String? {
        let left = together.joinMsLeft - milliseconds(since: receivedAt, at: date)
        guard left > 0 else { return nil }
        return Format.clock(seconds: Double((left + 999) / 1000))
    }

    private func milliseconds(since start: Date, at date: Date) -> Int64 {
        Int64((date.timeIntervalSince(start) * 1000).rounded())
    }
}
