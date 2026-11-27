import Foundation
import GRDB
import RabbitEarsAPI

public typealias ItemRelated = Components.Schemas.ItemRelated

/// The way from a detail page to the film or episode before or after it.
public struct Neighbor: Sendable {
    public let item: Item
    public let isNext: Bool

    /// `Previous: The Two Towers`, `Next: S2 E1`.
    public var title: String { "\(isNext ? "Next" : "Previous"): \(name)" }

    /// `Previous film, The Two Towers`, `Next episode, S2 E1`.
    public var accessibilityLabel: String {
        "\(isNext ? "Next" : "Previous") \(item.kind == .episode ? "episode" : "film"), \(name)"
    }

    private var name: String { item.kind == .episode ? Format.episodeCode(item) : Catalog.title(item) }
}

extension ItemRelated {
    /// Previous before Next, each only when there is one.
    public var neighbors: [Neighbor] {
        [previous.map { Neighbor(item: $0, isNext: false) }, next.map { Neighbor(item: $0, isNext: true) }]
            .compactMap { $0 }
    }
}

extension CatalogModel {
    /// As getItemRelated answers; nil for a title the profile may not see
    /// or an unread replica, so the page shows neither the collections nor
    /// the neighbors.
    public func related(_ id: Item.ID) async -> ItemRelated? {
        (try? await replica.read { [profileId] in try Self.related(id, profileId, $0) }) ?? nil
    }

    /// The movies each related collection lists at most.
    nonisolated static let relatedLimit = 10

    private nonisolated static func related(_ id: Item.ID, _ profile: Int64, _ db: Database) throws -> ItemRelated? {
        guard
            let kind = try String.fetchOne(
                db,
                sql: "SELECT kind FROM item WHERE id = ? AND kind IN ('movie', 'show', 'season', 'episode') AND id "
                    + ReplicaRows.seenBy, arguments: [id, profile])
        else { return nil }
        var around: (previous: Int64, next: Int64) = (0, 0)
        var collections: [(Components.Schemas.Collection, [Int64])] = []
        if kind == "movie" {
            around = try ReplicaRows.neighbors(
                db, from: ReplicaRows.franchise, order: ReplicaRows.collectionOrder, of: id, browsedBy: profile)
            collections = try Self.collections(holding: id, profile, db)
        } else if kind == "episode" {
            around = try ReplicaRows.neighbors(
                db, from: ReplicaRows.showEpisodes, order: ReplicaRows.episodeOrder, of: id, browsedBy: profile)
        }
        let items = Dictionary(
            try ReplicaRows.items(db, ids: [around.previous, around.next] + collections.flatMap(\.1)).map {
                ($0.id, $0)
            },
            uniquingKeysWith: { first, _ in first })
        return ItemRelated(
            collections: collections.map { .init(collection: $0.0, items: $0.1.compactMap { items[$0] }) },
            similar: [], previous: items[around.previous], next: items[around.next])
    }

    /// The collections holding the movie that the household and profile
    /// see, TMDB's first then the rest by name, each with the ids of the
    /// relatedLimit other movies nearest it; one with none is left out.
    private nonisolated static func collections(
        holding movie: Item.ID, _ profile: Int64, _ db: Database
    ) throws -> [(Components.Schemas.Collection, [Int64])] {
        // As collection.seen: an adult hiding kids' content still sees an empty one.
        let rows = try Row.fetchAll(
            db,
            sql: ReplicaRows.collectionSQL + """
                 WHERE (c.household_id = (SELECT household_id FROM replica_meta)
                        OR c.source = 'tmdb' AND (SELECT use_remote FROM metadata_setting)
                            AND (SELECT COUNT(*) FROM collection_movie n WHERE n.collection_id = c.id) >= 2)
                    AND (a.browse_mode = 0 OR movie_count > 0
                        OR a.browse_mode = 2
                            AND NOT EXISTS (SELECT 1 FROM collection_movie e WHERE e.collection_id = c.id))
                    AND EXISTS (SELECT 1 FROM collection_movie x WHERE x.collection_id = c.id AND x.item_id = ?)
                ORDER BY c.source != 'tmdb', c.name COLLATE NOCASE, c.id
                """, arguments: [profile, movie])
        return try rows.compactMap { row -> (Components.Schemas.Collection, [Int64])? in
            guard let collection = ReplicaRows.collection(row) else { return nil }
            let movies = try Self.around(movie, in: collection.id, profile, db)
            return movies.isEmpty ? nil : (collection, movies)
        }
    }

    /// collection.Repo.Around: the collection's other movies the profile
    /// browses nearest the movie, half before it and half after, a side
    /// short of its half giving the rest to the other. The movie places the
    /// window even when the profile does not browse it.
    private nonisolated static func around(
        _ movie: Item.ID, in collection: Int64, _ profile: Int64, _ db: Database
    ) throws -> [Int64] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT item.id, item.id IN (SELECT item_id FROM profile_item WHERE account_id = ?2) AS seen
                FROM collection_movie cm JOIN item ON item.id = cm.item_id WHERE cm.collection_id = ?1
                ORDER BY \(ReplicaRows.collectionOrder)
                """, arguments: [collection, profile])
        var others: [Int64] = []
        var at = 0
        for row in rows {
            let id: Int64 = row["id"]
            if id == movie {
                at = others.count
            } else if row["seen"] {
                others.append(id)
            }
        }
        let limit = relatedLimit
        let low = max(min(at - limit / 2, others.count - limit), 0)
        return Array(others[low..<min(low + limit, others.count)])
    }
}

extension Array {
    /// Swaps the page on top of a navigation stack for another, so Back
    /// returns to where the first was opened from.
    public mutating func replaceTop(with page: Element) {
        if isEmpty { append(page) } else { self[count - 1] = page }
    }
}
