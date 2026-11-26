import Foundation
import Observation
import RabbitEarsAPI

/// Selection mode over a library grid or list: which items are picked, and
/// the anchor a Shift-click extends from. The view passes the order it shows.
@MainActor
@Observable
public final class Selection {
    public private(set) var active = false
    public private(set) var picked: Set<Int64> = []
    public private(set) var inPickOrder: [Int64] = []
    private var anchor: Int64?
    /// True while Select all reads the pages it has not yet.
    public private(set) var gathering = false
    /// What the list on screen offers Select all; set by that list.
    @ObservationIgnored public var source: Source?
    @ObservationIgnored private(set) var gather: Task<Void, Never>?

    /// A screen's whole listing as filtered now: what is loaded, whether that
    /// is all of it, and how to read the rest.
    public struct Source {
        let ids: @MainActor () -> [Int64]
        let complete: @MainActor () -> Bool
        let load: @MainActor () async -> Void

        /// `pager` is asked each time, as a list makes a new pager when its filter changes.
        public init<Element>(
            _ pager: @escaping @MainActor () -> Pager<Element>?, id: @escaping @Sendable (Element) -> Int64
        ) {
            ids = { pager()?.items.map(id) ?? [] }
            complete = { pager()?.done ?? false }
            load = { await pager()?.loadAll() }
        }

        /// A listing held whole, as the catalog's.
        public init(ids: @escaping @MainActor () -> [Int64]) {
            self.ids = ids
            complete = { true }
            load = {}
        }
    }

    public init() {}

    public var count: Int { picked.count }

    /// How much of the listing Select all has in hand.
    public var loaded: Int { source?.ids().count ?? 0 }

    public func contains(_ id: Int64) -> Bool { picked.contains(id) }

    public func begin() { active = true }

    public func end() {
        gather?.cancel()
        gather = nil
        gathering = false
        active = false
        clear()
    }

    public func toggle(_ id: Int64) {
        if picked.remove(id) == nil {
            add([id])
        } else {
            inPickOrder.removeAll { $0 == id }
        }
        anchor = id
    }

    /// Picks everything from the anchor to id as shown; with no anchor shown, a toggle.
    public func extend(to id: Int64, in order: [Int64]) {
        guard let anchor, let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) else {
            return toggle(id)
        }
        add(order[min(from, to)...max(from, to)])
    }

    public func selectAll(_ ids: [Int64]) { add(ids) }

    /// Whether the whole listing, every page of it, is picked.
    public var allPicked: Bool {
        guard let source, source.complete() else { return false }
        let ids = source.ids()
        return !ids.isEmpty && ids.allSatisfy(picked.contains)
    }

    /// Picks the whole listing, reading the pages not yet loaded first, or
    /// with it all picked, clears the picks and stays in selection mode.
    /// Ending the selection cancels the reading; a page that fails picks nothing.
    public func toggleAll() {
        guard !gathering, let source else { return }
        if allPicked { return clear() }
        gathering = true
        gather = Task {
            await source.load()
            guard !Task.isCancelled else { return }
            // The listing now, which a filter changed meanwhile has made another, unread one.
            if let now = self.source, now.complete() { add(now.ids()) }
            gathering = false
        }
    }

    private func clear() {
        picked = []
        inPickOrder = []
        anchor = nil
    }

    private func add(_ ids: some Sequence<Int64>) {
        for id in ids where picked.insert(id).inserted { inPickOrder.append(id) }
    }

    /// The picked ids in the order shown.
    public func ordered(_ order: [Int64]) -> [Int64] { order.filter(picked.contains) }
}

/// What a library selection holds, which decides the actions it offers.
public enum SelectKind: Sendable {
    case movie, show, channel, video, album, artist, song

    /// Nothing from YouTube goes in a playlist.
    public var playlistKind: PlaylistKind? {
        switch self {
        case .movie: .movies
        case .show: .tv
        case .album, .artist, .song: .music
        case .channel, .video: nil
        }
    }

    public var watches: Bool { [.movie, .show, .channel, .video].contains(self) }
    /// Movies and shows take kids' content, channels for kids.
    public var kidsContent: Bool { [.movie, .show, .channel].contains(self) }
    public var youtube: Bool { self == .channel || self == .video }
}
