import Foundation
import Observation
import RabbitEarsAPI

/// Tuned in to one station: asks for playback, keeps what the server says
/// is on, and wakes the player when it must ask again, at the program's
/// end or, off the air, when the station resumes. On a live stream, which
/// plays on through programs and idents, a program's end only reads what
/// is on.
@MainActor
@Observable
public final class StationTuner {
    /// The station with what is on, from the last answer.
    public private(set) var station: Station
    /// The last ask answered off_air: the identity screen shows instead of a program.
    public private(set) var offAir = false
    /// The last ask answered the station's one continuous stream.
    public private(set) var live = false
    /// When the player asks again, or a live stream's station is read; nil when nothing more is scheduled.
    public private(set) var wakeAt: Date?
    /// Called when `wakeAt` passes.
    @ObservationIgnored public var onWake: (@MainActor () async -> Void)?

    private let client: Client
    private let replica: Replica
    private let profileId: UID
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private let sleep: @MainActor (Date) async throws -> Void
    @ObservationIgnored private var waker: Task<Void, Never>?

    /// What is on is read from `replica` as `profileId` sees it at `now`.
    /// Tests pass a `sleep` that returns at once; it throws when cancelled.
    /// The wait is a second at least: to a device whose clock runs ahead of
    /// the server's, the program on now has already ended.
    public init(
        client: Client, replica: Replica, profileId: UID, station: Station,
        now: @escaping @Sendable () -> Date = Date.init, calendar: Calendar = .autoupdatingCurrent,
        sleep: @escaping @MainActor (Date) async throws -> Void = { date in
            try await Task.sleep(for: .seconds(max(1, date.timeIntervalSinceNow)))
        }
    ) {
        self.client = client
        self.replica = replica
        self.profileId = profileId
        self.now = now
        self.calendar = calendar
        self.station = station
        self.sleep = sleep
    }

    /// Tunes in: the stream of what is on at its live position, or nil when
    /// the station is off the air. Any other refusal is thrown; one from a
    /// server that failed or could not be reached wakes the player to ask
    /// again in a few seconds.
    public func ask(_ request: Components.Schemas.StationPlaybackRequest) async throws -> PlaybackStream? {
        do {
            let tuned = try await client.startStationPlayback(path: .init(stationId: station.id), body: .json(request))
                .created.body.json
            station.onAir = tuned.onAir
            offAir = false
            live = tuned.stream.live == true
            wake(at: tuned.onAir.now?.endsAt ?? (live ? tuned.onAir.next?.startsAt : nil))
            return tuned.stream
        } catch let error where APIError.from(error)?.code == .offAir {
            offAir = true
            live = false
            // The refusal carries only when; the station says whether that is a gap or off schedule, and what is next.
            if let fresh = await read() { station = fresh }
            wake(at: APIError.from(error)?.resumesAt)
            return nil
        } catch {
            if APIError.from(error).map({ $0.status >= 500 }) ?? true { wake(at: Date(timeIntervalSinceNow: 5)) }
            throw error
        }
    }

    /// Arms the wait again for the same instant, as the app comes to the
    /// foreground or the device wakes, when a wait slept through may not fire.
    public func resume() {
        wake(at: wakeAt)
    }

    /// Stops waking, as on leaving the station.
    public func cancel() {
        waker?.cancel()
        waker = nil
        wakeAt = nil
    }

    /// Returns once the program the station had on at last word is over by its schedule.
    func programOver() async {
        if let end = station.onAir.now?.endsAt { try? await sleep(end) }
    }

    /// Reads what is on now, and waits for its end or the next start. A
    /// station that cannot be read is read again in a minute.
    private func follow() async {
        let fresh = await read()
        if let fresh { station = fresh }
        wake(at: fresh.map { $0.onAir.now?.endsAt ?? $0.onAir.next?.startsAt } ?? Date(timeIntervalSinceNow: 60))
    }

    private func read() async -> Station? {
        let (id, profile, at, calendar) = (station.id, profileId, now(), calendar)
        return try? await replica.read {
            try StationRows.stations($0, profile: profile, id: id, at: at, calendar: calendar).first
        }
    }

    private func wake(at date: Date?) {
        waker?.cancel()
        wakeAt = date
        guard let date else { return }
        waker = Task { [weak self, sleep] in
            do { try await sleep(date) } catch { return }
            guard !Task.isCancelled, let self else { return }
            // Its own task: asking again replaces this waker, and cancelling it must not cancel the ask.
            Task { if self.live { await self.follow() } else { await self.onWake?() } }
        }
    }
}

extension PlayerModel {
    /// Playing a station's continuous stream, which has no subtitle tracks to pick.
    public var live: Bool { stream?.live == true }

    /// Tunes in to a station, or asks it again: ends the session playing,
    /// then plays what is on at its live position. Off the air nothing
    /// plays until the tuner wakes it. While a tune-in is in flight this
    /// does nothing: that one answers what is on.
    public func tune(_ tuner: StationTuner) async {
        guard !stopped, !tuning else { return }
        tuning = true
        defer { tuning = false }
        station = tuner
        tuner.onWake = { [weak self, weak tuner] in
            guard let tuner else { return }
            await self?.retune(tuner)
        }
        repeat {
            tuneAgain = false
            await endSession()
            await begin { [audioTrackId, subtitleChoice] snapshot in
                var request = Components.Schemas.StationPlaybackRequest(
                    audioTrackId: audioTrackId, snapshot: snapshot, live: true)
                if case .track(let id) = subtitleChoice { request.subtitleTrackId = id }
                return try await tuner.ask(request)
            }
        } while tuneAgain && !stopped
    }

    /// Asks again for a wake or a change, which a tune-in in flight may
    /// have been asked before: that one then asks once more when done.
    func retune(_ tuner: StationTuner) async {
        if tuning {
            tuneAgain = true
            return
        }
        await tune(tuner)
    }

    /// The stream ended. Ahead of the program's scheduled end, as for a
    /// file shorter than its runtime, the tuner's wake at the end asks:
    /// asking now would join the same program past its stream's end. A
    /// live stream ends with its last program, which a player reaches a
    /// little ahead of the schedule, so the ask waits for that end.
    public func programEnded(_ tuner: StationTuner) async {
        if tuner.live {
            await tuner.programOver()
        } else if let end = tuner.wakeAt, end.timeIntervalSinceNow > 2 {
            return
        }
        await tune(tuner)
    }
}
