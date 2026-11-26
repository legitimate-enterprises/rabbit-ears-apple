import Foundation
import Observation
import RabbitEarsAPI

/// A page the server answers with the size of the whole listing.
public protocol CountedPage: Sendable {
    associatedtype Row: Sendable
    var items: [Row] { get }
    var nextOffset: Int? { get }
    var total: Int { get }
}

extension Components.Schemas.MusicAlbumPage: CountedPage {}
extension Components.Schemas.MusicArtistPage: CountedPage {}
extension Components.Schemas.MusicSongPage: CountedPage {}

/// One paged listing, read a page at a time as a view scrolls or all at
/// once. A failed page keeps what loaded, and the next call retries it.
@MainActor
@Observable
public final class Pager<Element: Sendable> {
    public private(set) var items: [Element] = []
    public private(set) var done = false
    public private(set) var error: String?
    public private(set) var loading = false
    /// How many rows the listing holds in all, once a page has said.
    public private(set) var total: Int?

    private struct Read {
        let rows: [Element]
        let next: Int?
        let total: Int?
    }

    private let fetch: @MainActor (Int?) async throws -> Read
    private var offset: Int?

    /// `fetch` answers a page and the offset of the next, nil on the last.
    public init(_ fetch: @escaping @MainActor (Int?) async throws -> ([Element], Int?)) {
        self.fetch = {
            let (rows, next) = try await fetch($0)
            return Read(rows: rows, next: next, total: nil)
        }
    }

    /// As `init`, for a page that also says how many rows the listing holds in all.
    public init<Page: CountedPage>(counted fetch: @escaping @MainActor (Int?) async throws -> Page)
    where Page.Row == Element {
        self.fetch = {
            let page = try await fetch($0)
            return Read(rows: page.items, next: page.nextOffset, total: page.total)
        }
    }

    /// The rows in the listing: its total, else those read so far.
    public var count: Int { total ?? items.count }

    /// False while more rows are to come and no page has given the total.
    public var countIsExact: Bool { total != nil || done }

    /// `1,210`, or `200+` while more are to come and the total is not known.
    public var countText: String { count.formatted() + (countIsExact ? "" : "+") }

    public func loadMore() async {
        guard !loading else { return }
        if done {
            // Done with an error is a failed pull; trying again reads the rows again.
            if error != nil { await refresh(reporting: true) }
            return
        }
        loading = true
        defer { loading = false }
        do {
            let read = try await fetch(offset)
            items += read.rows
            total = read.total
            offset = read.next
            done = read.next == nil
            error = nil
        } catch {
            // A read the caller cancelled is not a failure for the list to show.
            guard !Task.isCancelled else { return }
            fail(error)
        }
    }

    private func fail(_ error: any Error) {
        self.error = AppError.from(error, unauthorized: .signedOut).localizedDescription
    }

    /// Re-reads as many rows as are loaded, at least one page, and swaps them
    /// in once they all arrive, so a view never sees the list shrink. A failed
    /// read keeps the rows as they were, and sets `error` only for a pull
    /// (`reporting`): a quiet reload on a live event must not.
    public func refresh(reporting: Bool = false) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let wanted = items.count
            var fresh: [Element] = []
            var next: Int?
            var all: Int?
            repeat {
                let read = try await fetch(next)
                fresh += read.rows
                next = read.next
                all = read.total
            } while next != nil && fresh.count < wanted
            items = fresh
            total = all
            offset = next
            done = next == nil
            error = nil
        } catch {
            if reporting, !Task.isCancelled { fail(error) }
        }
    }

    /// Stops at the first failed page rather than retrying it in a loop. A
    /// page already on its way is waited for: skipping it would spin.
    public func loadAll() async {
        while !done && !Task.isCancelled {
            if loading {
                await Task.yield()
                continue
            }
            await loadMore()
            if error != nil { return }
        }
    }
}
