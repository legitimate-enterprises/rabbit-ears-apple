import Foundation
import GRDB
import Observation
import RabbitEarsAPI
import SwiftUI

public typealias ActiveOccasion = Components.Schemas.ActiveOccasion

extension ActiveOccasion {
    /// The server's playful phrase for a Home row, else the occasion's name.
    public var rowTitle: String {
        guard let headline, !headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return name }
        return headline
    }
}

/// One in-season occasion and its titles the profile browses.
public struct OccasionShelf: Identifiable, Sendable {
    public let occasion: ActiveOccasion
    public let items: [Item]
    public var id: Int64 { occasion.id }
    /// What the occasion is called on its own screen and in labels.
    public var name: String { occasion.name }
    /// What titles the row on Home.
    public var title: String { occasion.rowTitle }
}

/// Home's seasonal shelves, as the server would list them: the occasions in
/// season on the device's calendar day that hold a title the profile
/// browses, nearest their anchor first.
@MainActor
@Observable
public final class OccasionsModel {
    public private(set) var shelves: [OccasionShelf] = []
    /// A load has answered, with shelves or without, so Home holds their space no longer.
    public private(set) var answered = false

    public init() {}

    /// A replica that cannot be read keeps what shows.
    public func load(replica: Replica, profileId: Int64, now: Date = Date(), timeZone: TimeZone = .current) async {
        let day = Self.day(now, in: timeZone)
        let loaded = try? await replica.read { db in
            try Self.shelves(of: try Self.active(on: day, profileId, db), profileId, db)
        }
        guard !Task.isCancelled else { return }
        if let loaded { shelves = loaded }
        answered = true
    }

    /// The first titles of each occasion the profile browses, in the order
    /// given; one left with no title but `excluding` is left out.
    nonisolated static func shelves(
        of active: [ActiveOccasion], _ profile: Int64, _ db: Database, excluding itemId: Int64? = nil
    ) throws -> [OccasionShelf] {
        try active.map { occasion in
            // One more than a row shows, so leaving the title out still fills it.
            let items = try members(occasion.id, profile, db, limit: Catalog.homeShelfLimit + 1, offset: 0)
            return OccasionShelf(
                occasion: occasion, items: Array(items.filter { $0.id != itemId }.prefix(Catalog.homeShelfLimit)))
        }
        .filter { !$0.items.isEmpty }
    }

    /// An occasion's titles the profile browses, as listItems pages them by title.
    nonisolated static func members(
        _ occasion: Int64, _ profile: Int64, _ db: Database, limit: Int, offset: Int
    ) throws -> [Item] {
        try ReplicaRows.items(
            db,
            "i.id IN (SELECT item_id FROM occasion_member WHERE occasion_id = ?) AND i.id \(ReplicaRows.browsedBy)"
                + " ORDER BY \(ReplicaRows.titleOrder) LIMIT ? OFFSET ?", [occasion, profile, limit, offset])
    }

    /// listActiveOccasions: the occasions in season on `day` holding a
    /// title the profile browses, `itemId` among them when given, nearest
    /// their anchor first, then by name, each titled by a random phrase.
    nonisolated static func active(
        on day: String, _ profile: Int64, _ db: Database, holding itemId: Int64? = nil
    ) throws -> [ActiveOccasion] {
        guard let date = calendarDay(day) else { return [] }
        var holidays: [String: [Date]] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT key, day FROM holiday_date") {
            if let date = calendarDay(row["day"]) { holidays[row["key"], default: []].append(date) }
        }
        var phrases: [Int64: [String]] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT occasion_id, phrase FROM occasion_phrase") {
            phrases[row["occasion_id"], default: []].append(row["phrase"])
        }
        var found: [(ActiveOccasion, Int)] = []
        for row in try Row.fetchAll(db, sql: "SELECT * FROM occasion ORDER BY name, id") {
            let id: Int64 = row["id"]
            let holiday = (row["holiday"] as String?).flatMap { $0.isEmpty ? nil : holidays[$0, default: []] }
            let (month, monthDay): (Int, Int) = (row["month"] ?? 0, row["day"] ?? 0)
            guard
                let window = window(
                    on: date, before: row["days_before"], after: row["days_after"],
                    anchor: { anchor(in: $0, holiday: holiday, month: month, day: monthDay) }),
                try Bool.fetchOne(
                    db,
                    sql: """
                        SELECT 1 FROM occasion_member WHERE occasion_id = ? AND (?2 IS NULL OR item_id = ?2)
                            AND item_id \(ReplicaRows.browsedBy) LIMIT 1
                        """, arguments: [id, itemId, profile]) == true
            else { continue }
            let colors = (row["color1"] as String?).map {
                [$0, row["color2"] as String? ?? "", row["color3"] as String? ?? ""]
            }
            found.append(
                (
                    ActiveOccasion(
                        id: id, name: row["name"], headline: phrases[id]?.randomElement(), colors: colors,
                        anchorDate: text(window.anchor), firstDate: text(window.first), lastDate: text(window.last)),
                    window.distance
                ))
        }
        return found.enumerated().sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }.map(\.element.0)
    }

    struct Window {
        let anchor: Date
        let first: Date
        let last: Date
        let distance: Int
    }

    /// occasion.On: the window of the occasion containing `date`, if any,
    /// with `anchor` giving its anchor in a year. A window may start or end
    /// in the year next to its anchor's.
    nonisolated static func window(on date: Date, before: Int, after: Int, anchor: (Int) -> Date?) -> Window? {
        let year = utc.component(.year, from: date)
        for candidate in year - 1...year + 1 {
            guard let anchor = anchor(candidate),
                let first = utc.date(byAdding: .day, value: -before, to: anchor),
                let last = utc.date(byAdding: .day, value: after, to: anchor), first <= date, date <= last,
                let distance = utc.dateComponents([.day], from: min(date, anchor), to: max(date, anchor)).day
            else { continue }
            return Window(anchor: anchor, first: first, last: last, distance: distance)
        }
        return nil
    }

    /// A holiday's anchor in `year` is its date that year, as `holiday`
    /// lists them; else month and day, none in a year without that day.
    nonisolated static func anchor(in year: Int, holiday: [Date]?, month: Int, day: Int) -> Date? {
        if let holiday { return holiday.first { utc.component(.year, from: $0) == year } }
        guard let made = utc.date(from: DateComponents(year: year, month: month, day: day)),
            utc.component(.day, from: made) == day
        else { return nil }
        return made
    }

    /// Calendar days are worked at midnight UTC, as the server does.
    private nonisolated static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    private nonisolated static func calendarDay(_ text: String) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return utc.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private nonisolated static func text(_ date: Date) -> String { day(date, in: utc.timeZone) }

    /// `YYYY-MM-DD` on the device's calendar day, whatever its locale or calendar.
    nonisolated static func day(_ date: Date, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
}

extension CatalogModel {
    /// Every title the profile browses in an occasion, a page at a time, for its own screen.
    public func occasionMembers(_ id: Int64) -> Pager<Item> {
        Pager { [replica, profileId] offset in
            let start = offset ?? 0
            let page = try await replica.read {
                try OccasionsModel.members(id, profileId, $0, limit: 201, offset: start)
            }
            return (Array(page.prefix(200)), page.count > 200 ? start + 200 : nil)
        }
    }

    /// A details page's rows: each occasion in season the title is in, with its other titles.
    public func occasionRows(
        containing itemId: Int64, now: Date = Date(), timeZone: TimeZone = .current
    ) async -> [OccasionShelf] {
        let day = OccasionsModel.day(now, in: timeZone)
        return
            (try? await replica.read { [profileId] db in
                try OccasionsModel.shelves(
                    of: try OccasionsModel.active(on: day, profileId, db, holding: itemId), profileId, db,
                    excluding: itemId)
            }) ?? []
    }
}

/// Reloads Home's occasion shelves when Home appears, the catalog or profile
/// changes, the app returns to the foreground and the local day turns over.
private struct OccasionReload: ViewModifier {
    let occasions: OccasionsModel
    let catalog: CatalogModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppModel.self) private var app
    @State private var days = 0

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in days += 1 }
            .task(id: "\(catalog.profileId)/\(catalog.revision)/\(scenePhase == .active)/\(days)") {
                guard scenePhase == .active else { return }
                await occasions.load(replica: catalog.replica, profileId: catalog.profileId)
                guard occasions.answered, !Task.isCancelled else { return }
                app.homeShowed(occasions: occasions.shelves, profileId: catalog.profileId)
            }
    }
}

extension View {
    public func reloadingOccasions(_ occasions: OccasionsModel, with catalog: CatalogModel) -> some View {
        modifier(OccasionReload(occasions: occasions, catalog: catalog))
    }
}
