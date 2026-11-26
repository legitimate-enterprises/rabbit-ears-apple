import Foundation
import RabbitEarsAPI

public typealias WatchState = Components.Schemas.WatchState
public typealias ItemKind = Components.Schemas.ItemKind
public typealias Genre = Components.Schemas.Genre

public enum GridFilter: String, CaseIterable, Sendable {
    case all = "All"
    case unwatched = "Unwatched"
    case inProgress = "In progress"
    case kids = "Kids"
}

/// The views a Movies or TV screen switches between, in tab order.
public enum GridTab: Hashable, Sendable {
    case titles, collections, playlists, stations

    /// Collections group movies; Playlists shows when `playlists`, as
    /// `PlaylistsModel.offersView` decides.
    public static func tabs(_ kind: ItemKind, playlists: Bool) -> [GridTab] {
        [.titles] + (kind == .movie ? [.collections] : []) + (playlists ? [.playlists] : []) + [.stations]
    }

    public func title(_ kind: ItemKind) -> String {
        switch self {
        case .titles: kind == .movie ? "Movies" : "Shows"
        case .collections: "Collections"
        case .playlists: "Playlists"
        case .stations: "Stations"
        }
    }
}

public enum GridSort: String, CaseIterable, Sendable {
    case recentlyAdded = "Recently added"
    case title = "Title"
    case year = "Released"
}

/// A profile's whole catalog and watch state, with every derived list the
/// views show. Ceilings were applied by the server before it got here.
public struct Catalog: Sendable {
    public private(set) var items: [Item.ID: Item] = [:]
    public private(set) var watch: [Item.ID: WatchState] = [:]
    private var childIDs: [Item.ID: [Item.ID]] = [:]
    /// Kids' titles an adult hiding them reads for the Kids pill. They open and play like any
    /// title, and appear in no list but that pill's.
    private var apart: Set<Item.ID> = []

    public init(items: [Item] = [], watch: [WatchState] = []) {
        for state in watch { self.watch[state.itemId] = state }
        add(items)
    }

    private mutating func add(_ added: [Item]) {
        for item in added { items[item.id] = item }
        var parents: Set<Item.ID> = []
        for item in added {
            guard let parent = item.parentId else { continue }
            childIDs[parent, default: []].append(item.id)
            parents.insert(parent)
        }
        for parent in parents {
            childIDs[parent] = (childIDs[parent] ?? []).compactMap { items[$0] }.sorted(by: Self.numberOrder).map(\.id)
        }
    }

    /// Takes titles to keep apart; a show's seasons and episodes come with it.
    public mutating func hold(_ held: [Item]) {
        let fresh = held.filter { items[$0.id] == nil }
        apart.formUnion(fresh.map(\.id))
        add(fresh)
    }

    public mutating func record(_ state: WatchState) { watch[state.itemId] = state }

    public mutating func forget(_ id: Item.ID) { watch[id] = nil }

    /// Takes the server's copy of an item, as after a kids' content change.
    public mutating func replace(_ item: Item) { items[item.id] = item }

    public func item(_ id: Item.ID) -> Item? { items[id] }

    public func children(of id: Item.ID) -> [Item] { (childIDs[id] ?? []).compactMap { items[$0] } }

    public func parent(of item: Item) -> Item? { item.parentId.flatMap { items[$0] } }

    public func show(of item: Item) -> Item? {
        var current: Item? = item
        while let next = current, next.kind != .show { current = parent(of: next) }
        return current
    }

    /// Every episode under a show or season, in viewing order with specials last.
    public func episodes(under id: Item.ID) -> [Item] {
        guard let item = items[id] else { return [] }
        if item.kind == .episode { return [item] }
        if item.kind == .movie { return [] }
        return children(of: id).flatMap { $0.kind == .episode ? [$0] : episodes(under: $0.id) }
    }

    public func isWatched(_ id: Item.ID) -> Bool { watch[id]?.watched ?? false }

    public func isInProgress(_ id: Item.ID) -> Bool {
        guard let state = watch[id] else { return false }
        return state.positionMs > 0
    }

    public func unwatchedCount(_ id: Item.ID) -> Int {
        guard let item = items[id] else { return 0 }
        if item.kind == .movie || item.kind == .episode { return isWatched(id) ? 0 : 1 }
        return episodes(under: id).filter { !isWatched($0.id) }.count
    }

    public func durationMs(_ id: Item.ID) -> Int64? {
        items[id]?.metadata?.runtimeMinutes.map { Int64($0) * 60_000 }
    }

    public func progress(_ id: Item.ID) -> Double? {
        guard isInProgress(id), let position = watch[id]?.positionMs, let duration = durationMs(id), duration > 0
        else { return nil }
        return min(1, Double(position) / Double(duration))
    }

    public func remainingMs(_ id: Item.ID) -> Int64? {
        guard isInProgress(id), let position = watch[id]?.positionMs, let duration = durationMs(id) else { return nil }
        return max(0, duration - position)
    }

    public var continueWatching: [Item] {
        watch.values.filter { isInProgress($0.itemId) && items[$0.itemId] != nil && !apart.contains($0.itemId) }
            .sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
            .compactMap { items[$0.itemId] }
    }

    /// For each show whose latest play finished an episode, the episode after it.
    public var nextUp: [Item] {
        items.values.filter { $0.kind == .show && !apart.contains($0.id) }
            .compactMap { show -> (Item, Date)? in
                let episodes = episodes(under: show.id).filter { $0.seasonNumber != 0 }
                guard !episodes.contains(where: { isInProgress($0.id) }),
                    let latest = latestPlayed(episodes), isWatched(latest.id),
                    let index = episodes.firstIndex(where: { $0.id == latest.id }),
                    let next = episodes[(index + 1)...].first(where: { !isWatched($0.id) })
                else { return nil }
                return (next, watch[latest.id]?.lastPlayedAt ?? .distantPast)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// Tiles on each of Home's recently added and seasonal shelves.
    public static let homeShelfLimit = 20

    public var recentlyAdded: [Item] {
        Array(
            items.values.filter { ($0.kind == .movie || $0.kind == .show) && !apart.contains($0.id) }
                .sorted { $0.addedAt > $1.addedAt }.prefix(Self.homeShelfLimit))
    }

    /// The episode Play or Resume starts for a show or season.
    public func resumeTarget(for id: Item.ID) -> Item? {
        let all = episodes(under: id)
        let regular = all.filter { $0.seasonNumber != 0 }
        let episodes = regular.isEmpty ? all : regular
        if let current = latestPlayed(episodes.filter { isInProgress($0.id) }) { return current }
        if let latest = latestPlayed(episodes.filter { isWatched($0.id) }),
            let index = episodes.firstIndex(where: { $0.id == latest.id }),
            let next = episodes[(index + 1)...].first(where: { !isWatched($0.id) })
        {
            return next
        }
        return episodes.first { !isWatched($0.id) } ?? episodes.first
    }

    public func grid(
        _ kind: ItemKind, filter: GridFilter = .all, sort: GridSort = .recentlyAdded, genre: Genre.ID? = nil
    ) -> [Item] {
        items.values
            .filter { $0.kind == kind && (filter == .kids || !apart.contains($0.id)) }
            .filter { item in genre.map { id in item.genres?.contains { $0.id == id } ?? false } ?? true }
            .filter { item in
                switch filter {
                case .all: true
                case .unwatched: unwatchedCount(item.id) > 0
                case .inProgress: isInProgress(item.id) || showStarted(item)
                case .kids: item.kidsContent == true
                }
            }
            .sorted { lhs, rhs in
                switch sort {
                case .recentlyAdded: lhs.addedAt > rhs.addedAt
                case .title: Self.title(lhs).localizedStandardCompare(Self.title(rhs)) == .orderedAscending
                case .year: (Self.year(lhs) ?? 0) > (Self.year(rhs) ?? 0)
                }
            }
    }

    /// The count beside a grid: every title of the kind, or under the Kids pill the kids' content.
    public func total(_ kind: ItemKind, filter: GridFilter = .all) -> Int {
        grid(kind, filter: filter == .kids ? .kids : .all).count
    }

    /// The genres carried by any item of this kind, by name.
    public func genres(_ kind: ItemKind) -> [Genre] {
        var byID: [Genre.ID: Genre] = [:]
        for item in items.values where item.kind == kind && !apart.contains(item.id) {
            for genre in item.genres ?? [] { byID[genre.id] = genre }
        }
        return byID.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The grid caption, runtime first: `2h 46m · 2024`, `50m · 2 seasons`.
    public func caption(_ item: Item) -> String {
        var parts: [String] = []
        if let minutes = item.metadata?.runtimeMinutes, minutes > 0 { parts.append(Format.runtime(minutes: minutes)) }
        if item.kind == .show {
            let seasons = children(of: item.id).filter { $0.kind == .season && $0.seasonNumber != 0 }.count
            parts.append(Format.count(seasons, "season"))
        } else if let year = Self.year(item) {
            parts.append(String(year))
        }
        return parts.joined(separator: " · ")
    }

    public static func title(_ item: Item) -> String { item.metadata?.title ?? item.parsedTitle }

    public static func year(_ item: Item) -> Int? {
        item.parsedYear ?? item.metadata?.releaseDate.flatMap { Int($0.prefix(4)) }
    }

    private func showStarted(_ item: Item) -> Bool {
        guard item.kind == .show else { return false }
        let episodes = episodes(under: item.id)
        return episodes.contains { isInProgress($0.id) }
            || episodes.contains { isWatched($0.id) } && episodes.contains { !isWatched($0.id) }
    }

    private func latestPlayed(_ items: [Item]) -> Item? {
        items.filter { watch[$0.id] != nil }
            .max { (watch[$0.id]?.lastPlayedAt ?? .distantPast) < (watch[$1.id]?.lastPlayedAt ?? .distantPast) }
    }

    /// Seasons and episodes by number with specials (season 0) last, then title.
    private static func numberOrder(_ lhs: Item, _ rhs: Item) -> Bool {
        let key = { (item: Item) in
            (
                item.kind == .season && item.seasonNumber == 0 ? Int.max : item.seasonNumber ?? 0,
                item.kind == .episode ? item.episodeNumber ?? 0 : 0
            )
        }
        let (left, right) = (key(lhs), key(rhs))
        if lhs.kind == .episode && rhs.kind == .episode && lhs.seasonNumber != rhs.seasonNumber {
            return (lhs.seasonNumber ?? 0) < (rhs.seasonNumber ?? 0)
        }
        return left != right ? left < right : title(lhs) < title(rhs)
    }
}

/// `S2 E4 · Woe's Hollow · 23m left` for episodes, `1h 12m left` for movies.
public enum EpisodeText {
    /// What a screen reader says of a tile that plays at once: `Play Severance, S1 E2 Half Loop`.
    public static func playLabel(_ item: Item, _ catalog: Catalog) -> String {
        guard item.kind == .episode else { return "Play \(Catalog.title(item))" }
        return
            "Play \(Catalog.title(catalog.show(of: item) ?? item)), \(Format.episodeCode(item)) \(Catalog.title(item))"
    }

    public static func line(_ item: Item, _ catalog: Catalog) -> String {
        var parts: [String] = []
        if item.kind == .episode { parts += [Format.episodeCode(item), Catalog.title(item)] }
        if let left = catalog.remainingMs(item.id) {
            parts.append(Format.remaining(ms: left))
        } else if item.kind != .episode {
            parts.append(catalog.caption(item))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
