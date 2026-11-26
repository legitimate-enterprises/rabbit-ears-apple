import Foundation
import Observation
import RabbitEarsAPI

/// Named apart from Swift's `Collection` protocol, which the plain name would shadow.
public typealias MovieCollection = Components.Schemas.Collection

/// The movie collections the active profile may see, by name: TMDB's,
/// read-only, and the household's custom ones. The server answers a TMDB
/// write, or any while a kid is active, with 403.
@MainActor
@Observable
public final class CollectionsModel {
    public private(set) var collections: [MovieCollection] = []
    public private(set) var error: String?
    public let client: Client

    public init(client: Client) {
        self.client = client
    }

    /// The household's own, the only ones a movie can be added to.
    public var custom: [MovieCollection] { collections.filter { $0.source == .custom } }

    public func load() async {
        await write {
            collections = try await allPages { offset in
                let page = try await self.client.listCollections(query: .init(limit: 200, offset: offset)).ok.body
                    .json
                return (page.items, page.nextOffset)
            }
        }
    }

    /// Its movies in release order, every page; nil when they could not be read.
    /// A collection reached by a link is read too, as the list may not be loaded.
    public func movies(of collectionId: Int64) async -> [Item]? {
        var movies: [Item]?
        await write {
            if !collections.contains(where: { $0.id == collectionId }) {
                collections.append(
                    try await client.getCollection(path: .init(collectionId: collectionId)).ok.body.json)
            }
            movies = try await allPages { offset in
                let page = try await self.client.listCollectionMovies(
                    path: .init(collectionId: collectionId), query: .init(limit: 200, offset: offset)
                ).ok.body.json
                return (page.items, page.nextOffset)
            }
        }
        return movies
    }

    /// The collections a movie is in; only its details carry them.
    public func collections(of movieId: Int64) async -> [MovieCollection] {
        (try? await client.getItem(path: .init(itemId: movieId)).ok.body.json.collections) ?? []
    }

    @discardableResult
    public func create(name: String) async -> MovieCollection? {
        guard let name = Self.name(name) else { return nil }
        var created: MovieCollection?
        await write {
            let collection = try await client.createCollection(body: .json(.init(name: name))).created.body.json
            collections.append(collection)
            created = collection
        }
        return created
    }

    public func rename(_ collection: MovieCollection, to name: String) async {
        guard let name = Self.name(name) else { return }
        await write {
            replace(
                try await client.replaceCollection(
                    path: .init(collectionId: collection.id), body: .json(.init(name: name))
                ).ok.body.json)
        }
    }

    public func delete(_ collection: MovieCollection) async {
        await write {
            _ = try await client.deleteCollection(path: .init(collectionId: collection.id)).noContent
            collections.removeAll { $0.id == collection.id }
        }
    }

    /// False when the server refused, as for a TMDB collection.
    @discardableResult
    public func add(movie itemId: Int64, to collectionId: Int64) async -> Bool {
        await write {
            _ = try await client.addCollectionMovie(path: .init(collectionId: collectionId, itemId: itemId))
                .noContent
            try await refresh(collectionId)
        }
    }

    public func remove(movie itemId: Int64, from collectionId: Int64) async {
        await write {
            _ = try await client.removeCollectionMovie(path: .init(collectionId: collectionId, itemId: itemId))
                .noContent
            try await refresh(collectionId)
        }
    }

    /// Puts a movie at an index among all the collection's movies, hidden ones
    /// included; the answer says whether the collection is now hand-ordered.
    /// False when the server refused, as for a TMDB collection or a kid.
    @discardableResult
    public func move(_ itemId: Int64, in collectionId: Int64, to position: Int) async -> Bool {
        await write {
            replace(
                try await client.replaceCollectionMoviePosition(
                    path: .init(collectionId: collectionId, itemId: itemId), body: .json(.init(position: position))
                ).ok.body.json)
        }
    }

    /// Back to release order.
    @discardableResult
    public func resetOrder(of collectionId: Int64) async -> Bool {
        await write {
            replace(try await client.resetCollectionOrder(path: .init(collectionId: collectionId)).ok.body.json)
        }
    }

    /// `move`, then the movies as the server now holds them, so a screen shows the truth; a refusal's error stays.
    public func reorder(_ itemId: Int64, in collectionId: Int64, to position: Int) async -> [Item]? {
        await reading(collectionId) { await move(itemId, in: collectionId, to: position) }
    }

    /// `resetOrder`, then the movies as the server now holds them.
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

    /// The count and artwork change with every movie write.
    private func refresh(_ id: Int64) async throws {
        replace(try await client.getCollection(path: .init(collectionId: id)).ok.body.json)
    }

    private func replace(_ collection: MovieCollection) {
        guard let at = collections.firstIndex(where: { $0.id == collection.id }) else { return }
        collections[at] = collection
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
