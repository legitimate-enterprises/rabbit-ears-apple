import Foundation
import GRDB
import RabbitEarsAPI

/// The custom collection writes this device makes. Each change to one is
/// refused at once for a TMDB collection, as the server refuses it.
extension ActionQueue {
    /// createCollection: a custom collection of the device's household.
    func createCollection(as profile: UID, _ id: UID, name: String) async throws {
        try await act(
            as: profile, touching: [try .row("collection", id)],
            call: { client, _ in _ = try await client.createCollection(body: .json(.init(id: id, name: name))) },
            apply: { db, at in
                try db.execute(
                    sql: """
                        INSERT INTO collection(id, source, household_id, name, created_at, modified_at, created_by,
                            modified_by)
                        VALUES (?1, 'custom', (SELECT household_id FROM replica_meta), ?2, ?3, ?3, ?4, ?4)
                        """, arguments: [id, name, Self.ms(at), profile])
            })
    }

    func renameCollection(as profile: UID, _ id: UID, name: String) async throws {
        try await act(
            as: profile, touching: [try .row("collection", id)],
            call: { client, _ in
                _ = try await client.replaceCollection(path: .init(collectionId: id), body: .json(.init(name: name)))
            },
            apply: { db, at in
                try Self.custom(db, id)
                try db.execute(
                    sql: "UPDATE collection SET name = ?, modified_at = ?, modified_by = ? WHERE id = ?",
                    arguments: [name, Self.ms(at), profile, id])
            })
    }

    /// The playlist entries holding it go with it, as the server cascades;
    /// its movies stay until the server's tombstones arrive, read by nothing
    /// without their collection.
    func deleteCollection(as profile: UID, _ id: UID, entries: [UID]) async throws {
        try await act(
            as: profile, touching: [try .row("collection", id)] + entries.map { try .row("playlist_entry", $0) },
            call: { client, _ in _ = try await client.deleteCollection(path: .init(collectionId: id)) },
            apply: { db, _ in
                try Self.custom(db, id)
                try db.execute(sql: "DELETE FROM playlist_entry WHERE collection_id = ?", arguments: [id])
                try db.execute(sql: "DELETE FROM collection WHERE id = ?", arguments: [id])
            })
    }

    /// Last while the collection is hand-ordered; adding one already in it changes nothing.
    func addMovie(as profile: UID, _ movie: UID, to id: UID) async throws {
        try await act(
            as: profile, touching: [try .row("collection_movie", id, movie)],
            call: { client, _ in
                _ = try await client.addCollectionMovie(path: .init(collectionId: id, itemId: movie))
            },
            apply: { db, _ in
                try Self.custom(db, id)
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO collection_movie(collection_id, item_id, position)
                        VALUES (?1, ?2, (SELECT MAX(position) + 1 FROM collection_movie WHERE collection_id = ?1))
                        """, arguments: [id, movie])
            })
    }

    func removeMovie(as profile: UID, _ movie: UID, from id: UID) async throws {
        try await act(
            as: profile, touching: [try .row("collection_movie", id, movie)],
            call: { client, _ in
                _ = try await client.removeCollectionMovie(path: .init(collectionId: id, itemId: movie))
            },
            apply: { db, _ in
                try Self.custom(db, id)
                try db.execute(
                    sql: "DELETE FROM collection_movie WHERE collection_id = ? AND item_id = ?", arguments: [id, movie])
            })
    }

    /// Numbers every movie of the collection from 0 in `order`, the one it
    /// holds now with `movie` moved, as the server's MoveMovie.
    func moveMovie(as profile: UID, _ movie: UID, in id: UID, to position: Int, order: [UID]) async throws {
        try await act(
            as: profile, touching: try order.map { try .row("collection_movie", id, $0) },
            call: { client, _ in
                _ = try await client.replaceCollectionMoviePosition(
                    path: .init(collectionId: id, itemId: movie), body: .json(.init(position: position)))
            },
            apply: { db, _ in
                try Self.custom(db, id)
                var ids = order.filter { $0 != movie }
                ids.insert(movie, at: min(max(0, position), ids.count))
                try db.execute(
                    sql: """
                        UPDATE collection_movie SET position = j.key FROM json_each(?2) j
                        WHERE collection_id = ?1 AND item_id = unhex(j.value, '-')
                        """, arguments: [id, ReplicaRows.json(ids)])
            })
    }

    /// Back to release order: `order` names every movie of the collection.
    func resetOrder(as profile: UID, of id: UID, order: [UID]) async throws {
        try await act(
            as: profile, touching: try order.map { try .row("collection_movie", id, $0) },
            call: { client, _ in _ = try await client.resetCollectionOrder(path: .init(collectionId: id)) },
            apply: { db, _ in
                try Self.custom(db, id)
                try db.execute(
                    sql: "UPDATE collection_movie SET position = NULL WHERE collection_id = ?", arguments: [id])
            })
    }

    private static func custom(_ db: Database, _ id: UID) throws {
        guard try String.fetchOne(db, sql: "SELECT source FROM collection WHERE id = ?", arguments: [id]) == "custom"
        else { throw AppError.server("A TMDB collection cannot be changed.") }
    }
}
