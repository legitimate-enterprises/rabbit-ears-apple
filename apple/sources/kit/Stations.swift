import Foundation
import Observation
import RabbitEarsAPI

public typealias Station = Components.Schemas.Station
public typealias StationOnAir = Components.Schemas.StationOnAir
public typealias StationProgram = Components.Schemas.StationProgram
public typealias StationTimeRange = Components.Schemas.StationTimeRange
public typealias Weekday = Components.Schemas.Weekday

/// The stations the active profile may see, and the owner's edits to them.
/// The server decides every schedule, order and program; this only reads
/// and writes what it is given.
@MainActor
@Observable
public final class StationsModel {
    public private(set) var error: String?
    /// A refused save's messages by the field each names, as `name`.
    public private(set) var fieldErrors: [String: String] = [:]
    /// The active profile's own stations, for the sidebar and Add to station; `loadMine` reads them.
    public private(set) var mine: [Station] = []
    public let client: Client
    public let profileId: Int64

    public init(client: Client, profileId: Int64) {
        self.client = client
        self.profileId = profileId
    }

    /// Only the owner, active, edits, reschedules or deletes a station.
    public func isOwner(_ station: Station) -> Bool { station.ownerId == profileId }

    /// One kind's stations, or every kind's; nil when they could not be read.
    public func list(_ kind: PlaylistKind? = nil) async -> [Station]? {
        var stations: [Station]?
        await write {
            stations = try await allPages { offset in
                let page = try await self.client.listStations(query: .init(kind: kind, limit: 200, offset: offset))
                    .ok.body.json
                return (page.items, page.nextOffset)
            }
        }
        return stations
    }

    public func loadMine() async {
        if let all = await list() { mine = all.filter(isOwner) }
    }

    /// The profile's stations an item of this kind can be added to.
    public func mine(_ kind: PlaylistKind) -> [Station] { mine.filter { $0.kind == kind } }

    /// Home's On now: every station with something on, kinds mixed.
    public func onNow() async -> [Station] { Self.onNow(await list() ?? []) }

    public static func onNow(_ stations: [Station]) -> [Station] { stations.filter { $0.onAir.status == .onAir } }

    public func station(_ id: Int64) async -> Station? {
        var station: Station?
        await write { station = try await client.getStation(path: .init(stationId: id)).ok.body.json }
        return station
    }

    /// The programs that overlap today, which is the server's to name: a
    /// station's days are its local ones. Nil when they could not be read.
    public func schedule(of id: Int64) async -> [StationProgram]? {
        var programs: [StationProgram]?
        await write {
            programs = try await allPages { offset in
                let page = try await self.client.listStationSchedule(
                    path: .init(stationId: id), query: .init(limit: 200, offset: offset)
                ).ok.body.json
                return (page.items, page.nextOffset)
            }
        }
        return programs
    }

    /// Makes a station, or replaces station `id`; nil when the form is
    /// incomplete or the server refused, with `fieldErrors` set for a 400.
    public func save(_ form: StationForm, as id: Int64? = nil) async -> Station? {
        guard let input = form.input else { return nil }
        var saved: Station?
        fieldErrors = [:]
        await write {
            do {
                if let id {
                    saved = try await client.replaceStation(path: .init(stationId: id), body: .json(input)).ok.body.json
                } else {
                    saved = try await client.createStation(body: .json(input)).created.body.json
                }
            } catch {
                fieldErrors = APIError.from(error)?.fieldMessages ?? [:]
                throw error
            }
        }
        if let saved { keep(saved) }
        return saved
    }

    /// Reschedule now: the station with its new onAir.
    public func reschedule(_ id: Int64) async -> Station? {
        var station: Station?
        await write { station = try await client.rescheduleStation(path: .init(stationId: id)).ok.body.json }
        return station
    }

    @discardableResult
    public func delete(_ id: Int64) async -> Bool {
        await write {
            _ = try await client.deleteStation(path: .init(stationId: id)).noContent
            mine.removeAll { $0.id == id }
        }
    }

    private func keep(_ station: Station) {
        if let at = mine.firstIndex(where: { $0.id == station.id }) {
            mine[at] = station
        } else {
            mine.append(station)
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

/// The station editor's fields, and the input they send.
public struct StationForm: Equatable, Sendable {
    public enum Schedule: Sendable { case continuous, chosen }

    public var name = ""
    /// Chosen when the station is made; its playlist holds only this kind.
    public var kind: PlaylistKind
    public var order = Components.Schemas.StationOrder.playlist
    public var visibility = Components.Schemas.StationVisibility._private
    public var timing: Components.Schemas.StationTiming
    public var schedule = Schedule.continuous
    public var days: Set<Weekday> = []
    /// Ranges of the server's day as `HH:mm`, sent as entered.
    public var times: [StationTimeRange] = []

    public init(kind: PlaylistKind) {
        self.kind = kind
        timing = Self.timing(for: kind)
    }

    public init(_ station: Station) {
        name = station.name
        kind = station.kind
        order = station.order
        visibility = station.visibility
        timing = station.timing
        schedule = station.days.isEmpty && station.times.isEmpty ? .continuous : .chosen
        days = Set(station.days)
        times = station.times
    }

    /// Only an admin makes a station server wide or changes one back, so the editor shows it read-only.
    public var serverWide: Bool { visibility == .server }

    /// Nil until it has a name. It sends no playlist: the server makes the
    /// station its own, and keeps it on a replace. Continuous sends no days
    /// or times; a server station sends no visibility, which keeps it.
    public var input: Components.Schemas.StationInput? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let chosen = schedule == .chosen
        return .init(
            name: String(name.prefix(100)), order: order, visibility: .init(rawValue: visibility.rawValue),
            timing: timing, days: chosen ? Weekday.allCases.filter(days.contains) : [], times: chosen ? times : [],
            kind: kind)
    }

    public static func timing(for kind: PlaylistKind) -> Components.Schemas.StationTiming {
        switch kind {
        case .movies: .hour
        case .tv: .halfHour
        case .music: .continuous
        }
    }

    /// An `HH:mm` as a date in a fixed UTC day, for a time picker shown in UTC, so no zone shifts it.
    public static func date(_ clock: String) -> Date {
        let parts = clock.split(separator: ":").compactMap { Int($0) }
        let minutes = parts.count == 2 ? parts[0] * 60 + parts[1] : 0
        return Date(timeIntervalSinceReferenceDate: Double(minutes * 60))
    }

    public static func clock(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// The UTC zone `date` and `clock` read in.
    public static let zone = TimeZone(identifier: "UTC")!
}
