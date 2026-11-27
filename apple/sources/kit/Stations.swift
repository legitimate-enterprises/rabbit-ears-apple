import Foundation
import GRDB
import Observation
import RabbitEarsAPI

public typealias Station = Components.Schemas.Station
public typealias StationOnAir = Components.Schemas.StationOnAir
public typealias StationProgram = Components.Schemas.StationProgram
public typealias StationTimeRange = Components.Schemas.StationTimeRange
public typealias Weekday = Components.Schemas.Weekday

/// The stations the active profile may see, read from the replica at
/// `now`, and the owner's edits to them. The server writes every schedule,
/// order and program; this reads them and what is on.
@MainActor
@Observable
public final class StationsModel {
    public private(set) var error: String?
    /// A refused save's messages by the field each names, as `name`.
    public private(set) var fieldErrors: [String: String] = [:]
    /// The active profile's own stations, for the sidebar and Add to station; `loadMine` reads them.
    public private(set) var mine: [Station] = []
    public let client: Client
    public let profileId: UID
    private let replica: Replica
    private let queue: ActionQueue
    private let now: @Sendable () -> Date
    /// Whose days and hours a schedule's days, ranges and today are.
    private let calendar: Calendar
    private let sleep: @MainActor (Date) async throws -> Void
    /// When the one pending wake at a program's start or end is due.
    @ObservationIgnored private var wakeAt: Date?

    /// Tests pass a `sleep` that returns when they say; it throws when cancelled.
    public init(
        client: Client, replica: Replica, queue: ActionQueue, profileId: UID,
        now: @escaping @Sendable () -> Date = Date.init, calendar: Calendar = .autoupdatingCurrent,
        sleep: @escaping @MainActor (Date) async throws -> Void = { date in
            try await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
        }
    ) {
        self.client = client
        self.replica = replica
        self.queue = queue
        self.profileId = profileId
        self.now = now
        self.calendar = calendar
        self.sleep = sleep
    }

    /// Only the owner, active, edits, reschedules or deletes a station.
    public func isOwner(_ station: Station) -> Bool { station.ownerId == profileId }

    /// One kind's stations, or every kind's; nil when they could not be read.
    public func list(_ kind: PlaylistKind? = nil) async -> [Station]? { await stations(kind: kind) }

    public func loadMine() async {
        if let all = await list() { mine = all.filter(isOwner) }
    }

    /// The profile's stations an item of this kind can be added to.
    public func mine(_ kind: PlaylistKind) -> [Station] { mine.filter { $0.kind == kind } }

    /// Home's On now: every station with something on, kinds mixed.
    public func onNow() async -> [Station] { Self.onNow(await list() ?? []) }

    public static func onNow(_ stations: [Station]) -> [Station] { stations.filter { $0.onAir.status == .onAir } }

    /// Nil when the profile may not see it, or it could not be read.
    public func station(_ id: UID) async -> Station? { await stations(id: id)?.first }

    /// The programs that overlap this device's today. Nil when the station
    /// is not the profile's to see or could not be read.
    public func schedule(of id: UID) async -> [StationProgram]? {
        await read { [profileId, calendar] db, at in
            try StationRows.schedule(db, station: id, profile: profileId, at: at, calendar: calendar)
        } ?? nil
    }

    /// Makes a station, or replaces station `id`, queued: it reads back at
    /// once, offline too; nil when the form is incomplete or the write could
    /// not be queued. A range equal to one the station has keeps its id.
    /// The server's refusal arrives as the queue's notice; `fieldErrors`
    /// holds only what is checked here.
    public func save(_ form: StationForm, as id: UID? = nil) async -> Station? {
        fieldErrors = [:]
        guard var input = form.input else { return nil }
        if let unaired = form.unairedTimes {
            fieldErrors["times"] = unaired
            return nil
        }
        let stored: Station? = if let id { await station(id) } else { nil }
        let saved = id ?? UID.new()
        input.times = Self.identified(input.times ?? [], keeping: stored?.times ?? [])
        let queued = await write {
            if let id {
                try await queue.replaceStation(id, input, stored: stored, as: profileId)
            } else {
                try await queue.createStation(saved, ownPlaylist: UID.new(), input, as: profileId)
            }
        }
        guard queued, let station = await station(saved) else { return nil }
        keep(station)
        return station
    }

    /// Each range takes the id of an equal one in `stored`, each such id
    /// once, and the rest new ids, as the server keeps a range's id.
    private static func identified(
        _ ranges: [StationTimeRange], keeping stored: [StationTimeRange]
    ) -> [StationTimeRange] {
        var free = stored
        func same(_ lhs: StationTimeRange, _ rhs: StationTimeRange) -> Bool {
            StationRows.minutes(lhs.from) == StationRows.minutes(rhs.from)
                && StationRows.minutes(lhs.to) == StationRows.minutes(rhs.to)
        }
        return ranges.map { range in
            var range = range
            if let at = free.firstIndex(where: { $0.id != nil && same($0, range) }) {
                range.id = free.remove(at: at).id
            } else {
                range.id = UID.new()
            }
            return range
        }
    }

    /// Reschedule now, queued: the new schedule arrives once the server has made it.
    @discardableResult
    public func reschedule(_ id: UID) async -> Bool {
        await write { try await queue.rescheduleStation(id, as: profileId) }
    }

    /// Queued: gone here at once, and from the server when the queue reaches it.
    @discardableResult
    public func delete(_ id: UID) async -> Bool {
        await write {
            try await queue.deleteStation(id, as: profileId)
            mine.removeAll { $0.id == id }
        }
    }

    private func stations(kind: PlaylistKind? = nil, id: UID? = nil) async -> [Station]? {
        let stations = await read { [profileId, calendar] db, at in
            try StationRows.stations(db, profile: profileId, kind: kind, id: id, at: at, calendar: calendar)
        }
        wake(after: stations ?? [])
        return stations
    }

    /// What is on changes when a program starts or ends, which commits nothing; the soonest such
    /// moment among `stations` moves the stations count once, so every board showing them reads them again.
    private func wake(after stations: [Station]) {
        let at = now()
        let moments = stations.flatMap { [$0.onAir.now, $0.onAir.next].compactMap { $0 } }
            .flatMap { [$0.startsAt, $0.endsAt] }.filter { $0 > at }
        guard let next = moments.min(), wakeAt.map({ next < $0 }) ?? true else { return }
        wakeAt = next
        Task { [weak self, replica, sleep] in
            guard (try? await sleep(next)) != nil else { return }
            if self?.wakeAt == next { self?.wakeAt = nil }
            replica.elapsed(.stations)
        }
    }

    private func keep(_ station: Station) {
        if let at = mine.firstIndex(where: { $0.id == station.id }) {
            mine[at] = station
        } else {
            mine.append(station)
        }
    }

    /// Nil, and `error` set, when the replica could not be read; nil alone before its first snapshot.
    private func read<T: Sendable>(_ body: @escaping @Sendable (Database, Date) throws -> T) async -> T? {
        let at = now()
        do {
            let value = try await replica.read { try body($0, at) }
            error = nil
            return value
        } catch Replica.Failure.empty {
            return nil
        } catch {
            self.error = AppError.from(error).localizedDescription
            return nil
        }
    }

    @discardableResult
    private func write(_ body: () async throws -> Void) async -> Bool {
        do {
            try await body()
            error = nil
            return true
        } catch {
            self.error = AppError.from(error, unauthorized: .signedOut).localizedDescription
            return false
        }
    }
}

/// The words the boards put on a station's tile, page and player. Times
/// are this device's, in its locale; the server's clock decided them.
public enum StationText {
    /// A movie by its title, an episode by its show and code, a song by its artist.
    public static func title(_ program: StationProgram) -> String {
        if let song = program.song { return "\(song.title) · \(song.artistName)" }
        guard let item = program.item else { return "" }
        if let show = program.show { return "\(Catalog.title(show)) · \(Format.episodeCode(item))" }
        return PlaylistText.named(Catalog.title(item), edition: program.editionName)
    }

    /// The tile's caption: what is on and next, what is next, or when it is back.
    public static func lines(
        _ onAir: StationOnAir, kind: PlaylistKind, calendar: Calendar = .current, now: Date = .now
    ) -> [String] {
        switch onAir.status {
        case .onAir:
            return [onAir.now.map { "On now: \(title($0))" }, next(onAir, kind: kind, calendar: calendar)]
                .compactMap { $0 }
        case .betweenPrograms, .offSchedule:
            return [waiting(onAir, kind: kind, calendar: calendar, now: now)]
        }
    }

    /// `Next: Salt and Ember at 4:00 PM`; a song has no time, since songs run back to back.
    public static func next(_ onAir: StationOnAir, kind: PlaylistKind, calendar: Calendar = .current) -> String? {
        guard let next = onAir.next else { return nil }
        return kind == .music
            ? "Next: \(title(next))" : "Next: \(title(next)) at \(time(next.startsAt, calendar))"
    }

    /// The identity screen's line when nothing plays: what is next and when
    /// between programs, when the station is back off schedule.
    public static func waiting(
        _ onAir: StationOnAir, kind: PlaylistKind, calendar: Calendar = .current, now: Date = .now
    ) -> String {
        guard let next = onAir.next else { return "Off the air" }
        guard onAir.status == .offSchedule else { return "Up next at \(time(next.startsAt, calendar)): \(title(next))" }
        let day =
            calendar.isDate(next.startsAt, inSameDayAs: now)
            ? "today"
            : next.startsAt.formatted(
                Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
                    .weekday(.wide))
        return "Back \(day) at \(time(next.startsAt, calendar))"
    }

    /// The page's line: `On now: X, 40m left. Next: Y at 4:00 PM.`
    public static func summary(
        _ onAir: StationOnAir, kind: PlaylistKind, calendar: Calendar = .current, now: Date = .now
    ) -> String {
        guard onAir.status == .onAir, let playing = onAir.now else {
            return waiting(onAir, kind: kind, calendar: calendar, now: now) + "."
        }
        let left = Int64(playing.endsAt.timeIntervalSince(now) * 1000)
        let line = "On now: \(title(playing)), \(Format.remaining(ms: max(0, left)))."
        return next(onAir, kind: kind, calendar: calendar).map { "\(line) \($0)." } ?? line
    }

    /// Where the station is in a program by the clock, which is where every viewer is.
    public static func progress(_ program: StationProgram, at now: Date) -> StationProgress {
        let total = max(1, program.endsAt.timeIntervalSince(program.startsAt))
        let elapsed = min(total, max(0, now.timeIntervalSince(program.startsAt)))
        return StationProgress(elapsed: elapsed, remaining: total - elapsed, fraction: elapsed / total)
    }

    /// Home's On now tile: the station's name behind its kind, as `Movies: Marvel`.
    public static func onNowName(_ station: Station) -> String {
        let kind =
            switch station.kind {
            case .movies: "Movies"
            case .tv: "TV"
            case .music: "Music"
            }
        return "\(kind): \(station.name)"
    }

    /// What a screen reader says of Home's On now tile, which tunes in: `Watch Movies: Marvel`.
    public static func onNowLabel(_ station: Station) -> String {
        "\(station.kind == .music ? "Listen to" : "Watch") \(onNowName(station))"
    }

    /// How far through the program on, 0 to 1, as the server answered; nil with no program or length.
    public static func onNowFraction(_ onAir: StationOnAir) -> Double? {
        guard let length = onAir.now?.durationMs, length > 0, let position = onAir.positionMs else { return nil }
        return min(1, Double(position) / Double(length))
    }

    /// A music station's Up next, read only, in the order the server will play it.
    public static func upNext(_ onAir: StationOnAir) -> [MusicSong] { onAir.upNext.compactMap(\.song) }

    /// What a tile shows: what is on, else what is next; nil draws the station's own tile.
    public static func art(_ onAir: StationOnAir) -> StationProgram? { onAir.now ?? onAir.next }

    public static func kind(_ kind: PlaylistKind) -> String {
        switch kind {
        case .movies: "Movies station"
        case .tv: "TV station"
        case .music: "Music station"
        }
    }

    /// Asked once the owner saves a station or changes what it plays.
    public static let rescheduleQuestion = "Reschedule now?"
    public static let rescheduleAnswers =
        "Now: what is on finishes, then the new schedule starts. "
        + "Later: what is scheduled plays out, and the change follows as the schedule is extended."

    public static func timing(_ timing: Components.Schemas.StationTiming) -> String {
        switch timing {
        case .continuous: "Back to back"
        case .halfHour: "On the hour or half hour"
        case .hour: "On the hour"
        }
    }

    /// Music has no rating scale, and an unrated station has none.
    public static func rating(_ station: Station) -> String { station.rating ?? "None" }

    public static func visibility(_ visibility: Components.Schemas.StationVisibility) -> String {
        switch visibility {
        case ._private: "Private"
        case .household: "Household"
        case .server: "Server"
        }
    }

    public static func time(_ date: Date, _ calendar: Calendar = .current) -> String {
        date.formatted(
            Date.FormatStyle(
                date: .omitted, time: .shortened, locale: calendar.locale ?? .current, calendar: calendar,
                timeZone: calendar.timeZone))
    }
}

/// Seconds into and left of a program, and the share played.
public struct StationProgress: Equatable, Sendable {
    public let elapsed: TimeInterval
    public let remaining: TimeInterval
    public let fraction: Double
}
