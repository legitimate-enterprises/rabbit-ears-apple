import Foundation
import GRDB
import Observation
import RabbitEarsAPI

/// Named apart from Swift's `Collection` protocol, which the plain name would shadow.
public typealias MovieCollection = Components.Schemas.Collection

/// The movie collections the active profile may see, by name: TMDB's,
/// read-only, and the household's custom ones. A TMDB write is refused at
/// once; the server rejects any while a kid is active.
@MainActor
@Observable
public final class CollectionsModel {
    public private(set) var collections: [MovieCollection] = []
    public private(set) var error: String?
    public let client: Client
    public let replica: Replica
    public let queue: ActionQueue
    public let engine: SyncEngine
    /// The active profile, whose view of each collection is read.
    public let profileId: Int64

    public init(client: Client, replica: Replica, queue: ActionQueue, engine: SyncEngine, profileId: Int64) {
        self.client = client
        self.replica = replica
        self.queue = queue
        self.engine = engine
        self.profileId = profileId
    }

    /// The household's own, the only ones a movie can be added to.
    public var custom: [MovieCollection] { collections.filter { $0.source == .custom } }

    /// Before the replica's first snapshot nothing is loaded.
    public func load() async {
        await write {
            do {
                try await reload()
            } catch Replica.Failure.empty {}
        }
    }

    /// Its movies in collection order; nil when they could not be read.
    /// A collection reached by a link is read too, as the list may not be loaded.
    public func movies(of collectionId: Int64) async -> [Item]? {
        var movies: [Item]?
        await write {
            let (collection, read) = try await replica.read { [profileId] db in
                (
                    try CollectionRows.list(db, profile: profileId, only: collectionId).first,
                    try CollectionRows.movies(db, profile: profileId, of: collectionId)
                )
            }
            guard let collection else { throw AppError.server("not found") }
            if !collections.contains(where: { $0.id == collectionId }) { collections.append(collection) }
            movies = read
        }
        return movies
    }

    /// The collections holding the movie that the profile may see.
    public func collections(of movieId: Int64) async -> [MovieCollection] {
        (try? await replica.read { [profileId] in try CollectionRows.list($0, profile: profileId, holding: movieId) })
            ?? []
    }

    // shortcut: online-only until offline ids are decided
    @discardableResult
    public func create(name: String) async -> MovieCollection? {
        guard let name = Self.name(name) else { return nil }
        var created: MovieCollection?
        await write {
            created = try await client.createCollection(body: .json(.init(name: name))).created.body.json
            try? await engine.catchUp()
            try await reload()
        }
        return created
    }

    public func rename(_ collection: MovieCollection, to name: String) async {
        guard let name = Self.name(name) else { return }
        await write {
            try await queue.renameCollection(as: profileId, collection.id, name: name)
            try await reload()
        }
    }

    public func delete(_ collection: MovieCollection) async {
        await write {
            let entries = try await replica.read {
                try Int64.fetchAll(
                    $0, sql: "SELECT id FROM playlist_entry WHERE collection_id = ?", arguments: [collection.id])
            }
            try await queue.deleteCollection(as: profileId, collection.id, entries: entries)
            try await reload()
        }
    }

    /// False when it was refused, as for a TMDB collection.
    @discardableResult
    public func add(movie itemId: Int64, to collectionId: Int64) async -> Bool {
        await write {
            try await queue.addMovie(as: profileId, itemId, to: collectionId)
            try await reload()
        }
    }

    public func remove(movie itemId: Int64, from collectionId: Int64) async {
        await write {
            try await queue.removeMovie(as: profileId, itemId, from: collectionId)
            try await reload()
        }
    }

    /// Puts a movie at an index among all the collection's movies, hidden ones
    /// included; the answer says whether the collection is now hand-ordered.
    /// False when it was refused, as for a TMDB collection.
    @discardableResult
    public func move(_ itemId: Int64, in collectionId: Int64, to position: Int) async -> Bool {
        await write {
            let order = try await replica.read { try CollectionRows.order($0, of: collectionId) }
            guard order.contains(itemId) else { throw AppError.server("not found") }
            try await queue.moveMovie(as: profileId, itemId, in: collectionId, to: position, order: order)
            try await reload()
        }
    }

    /// Back to release order.
    @discardableResult
    public func resetOrder(of collectionId: Int64) async -> Bool {
        await write {
            let order = try await replica.read { try CollectionRows.order($0, of: collectionId) }
            try await queue.resetOrder(as: profileId, of: collectionId, order: order)
            try await reload()
        }
    }

    /// `move`, then the movies as they now stand, so a screen shows the truth; a refusal's error stays.
    public func reorder(_ itemId: Int64, in collectionId: Int64, to position: Int) async -> [Item]? {
        await reading(collectionId) { await move(itemId, in: collectionId, to: position) }
    }

    /// `resetOrder`, then the movies as they now stand.
    public func restoreReleaseOrder(of collectionId: Int64) async -> [Item]? {
        await reading(collectionId) { await resetOrder(of: collectionId) }
    }

    private func reading(_ collectionId: Int64, after write: () async -> Bool) async -> [Item]? {
        let done = await write()
        let refusal = done ? nil : error
        let movies = await movies(of: collectionId)
        error = error ?? refusal
        return movies
    }

    /// `2016 · 2h 4m`, as a row in a collection's order list reads.
    public static func detail(of movie: Item) -> String {
        [Catalog.year(movie).map(String.init), movie.metadata?.runtimeMinutes.map(Format.runtime)]
            .compactMap(\.self).joined(separator: " · ")
    }

    /// The index a drop lands on: SwiftUI's offset counts the moved row itself when below its old place.
    public static func position(moving from: Int, toOffset destination: Int) -> Int {
        destination > from ? destination - 1 : destination
    }

    private func reload() async throws {
        collections = try await replica.read { [profileId] in try CollectionRows.list($0, profile: profileId) }
    }

    private static func name(_ name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : String(name.prefix(100))
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

extension MovieCollection {
    /// `3 movies`, counting those the profile may see.
    public var summary: String { Format.count(movieCount, "movie") }
    /// Whether it carries the In your order badge; a copy kept without the flag is in release order.
    public var isHandOrdered: Bool { customOrder ?? false }
}
