import Foundation
import RabbitEarsAPI

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
            name: name.prefix(scalars: 100), order: order, visibility: .init(rawValue: visibility.rawValue),
            timing: timing, days: chosen ? Weekday.allCases.filter(days.contains) : [], times: chosen ? times : [],
            kind: kind)
    }

    /// The server's refusal of the first range in which no program could
    /// start, word for word; nil when every range holds a start.
    var unairedTimes: String? {
        guard schedule == .chosen, let range = times.first(where: { !Self.holds($0, timing) }) else { return nil }
        return "\(range.from) to \(range.to) holds no \(timing.rawValue) start, so nothing would air"
    }

    /// As the server's Range.Holds: the first `timing` boundary at or after
    /// `from` falls before `to`, which at or before `from` is the next day's.
    static func holds(_ range: StationTimeRange, _ timing: Components.Schemas.StationTiming) -> Bool {
        let from = StationRows.minutes(range.from)
        let to = StationRows.minutes(range.to)
        let step =
            switch timing {
            case .continuous: 1
            case .halfHour: 30
            case .hour: 60
            }
        return (from + step - 1) / step * step < (to > from ? to : to + 24 * 60)
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
