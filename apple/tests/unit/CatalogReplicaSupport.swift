import Foundation
import GRDB
import RabbitEarsAPI

@testable import RabbitEarsKit

/// Rows of sync schema 1 for editions, collections, credits, occasions and playlists.
extension Database {
    /// An edition of `item`, `tag` nil for an untagged cut.
    func edition(_ id: UID, of item: UID, tag: String? = nil, runtimeMs: Int64? = nil) throws {
        try execute(
            sql: "INSERT INTO edition(id, item_id, tag, runtime_ms) VALUES (?, ?, ?, ?)",
            arguments: [id, item, tag, runtimeMs])
    }

    /// A file of `edition`, with a video track of `width` x `height` unless both are nil.
    func file(
        _ id: UID, in edition: UID, width: Int? = nil, height: Int? = nil, hdr: String? = nil,
        size: Int64 = 1000, durationMs: Int64? = nil, missing: Bool = false
    ) throws {
        try execute(
            sql: "INSERT INTO media_file(id, size_bytes, duration_ms, missing_at) VALUES (?, ?, ?, ?)",
            arguments: [id, size, durationMs, missing ? 1 : nil])
        try execute(
            sql: "INSERT INTO edition_file(edition_id, media_file_id) VALUES (?, ?)", arguments: [edition, id])
        if width != nil || height != nil {
            try execute(
                sql: """
                    INSERT INTO track(id, media_file_id, stream_index, kind, codec, width, height, hdr_format)
                    VALUES (?, ?, 0, 'video', 'h264', ?, ?, ?)
                    """, arguments: [UID.new(), id, width, height, hdr])
        }
    }

    /// One edition holding one file on disk, for an item that only needs to be playable.
    func playable(_ item: UID, missing: Bool = false) throws {
        let (edition, file) = (UID.new(), UID.new())
        try self.edition(edition, of: item)
        try self.file(file, in: edition, missing: missing)
    }

    /// A collection holding `movies` in order; `positions` sets a hand order.
    func collection(
        _ id: UID, _ name: String, source: String = "custom", household: UID? = 7, movies: [UID],
        positions: Bool = false
    ) throws {
        // Ten times the n of a `UID.n` id, as each TMDB collection has its own.
        let tmdbID = withUnsafeBytes(of: id.uuid.uuid) { $0.suffix(6).reduce(Int64(0)) { $0 << 8 | Int64($1) } } * 10
        try execute(
            sql: "INSERT INTO collection(id, source, household_id, tmdb_id, name, created_at, modified_at) "
                + "VALUES (?, ?, ?, ?, ?, 0, 0)",
            arguments: [id, source, source == "tmdb" ? nil : household, source == "tmdb" ? tmdbID : nil, name])
        for (index, movie) in movies.enumerated() {
            try execute(
                sql: "INSERT INTO collection_movie(collection_id, item_id, position) VALUES (?, ?, ?)",
                arguments: [id, movie, positions ? index : nil])
        }
    }

    func credit(
        _ id: UID, item: UID, person: UID, kind: String, position: Int, character: String? = nil,
        job: String? = nil
    ) throws {
        try execute(
            sql: "INSERT INTO credit(id, item_id, person_id, kind, character, job, position)"
                + " VALUES (?, ?, ?, ?, ?, ?, ?)",
            arguments: [id, item, person, kind, character, job, position])
    }

    func person(
        _ id: UID, _ name: String, tmdb: Int64? = nil, profilePath: String? = nil, headshot: String? = nil
    ) throws {
        try execute(
            sql: "INSERT INTO person(id, tmdb_id, name, profile_path, headshot_url) VALUES (?, ?, ?, ?, ?)",
            arguments: [id, tmdb, name, profilePath, headshot])
    }

    /// An occasion anchored to a holiday key, or else to month and day, with titles added by hand and the
    /// server's default wash.
    func occasion(
        _ id: UID, _ name: String, holiday: String? = nil, month: Int? = nil, day: Int? = nil, before: Int,
        after: Int, members: [UID] = [], phrases: [String] = [], colors: [String]? = nil
    ) throws {
        try execute(
            sql: """
                INSERT INTO occasion(id, name, holiday, month, day, days_before, days_after, color1, color2, color3,
                    created_at, modified_at, wash_strength, wash_brightness, wash_sharpness, wash_reach)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0, 200, 15, 0, 100)
                """,
            arguments: [id, name, holiday, month, day, before, after, colors?[0], colors?[1], colors?[2]])
        for member in members {
            try execute(sql: "INSERT INTO occasion_item(occasion_id, item_id) VALUES (?, ?)", arguments: [id, member])
        }
        for phrase in phrases {
            try execute(sql: "INSERT INTO occasion_phrase(occasion_id, phrase) VALUES (?, ?)", arguments: [id, phrase])
        }
    }

    func holiday(_ key: String, on days: [String]) throws {
        for day in days { try execute(sql: "INSERT INTO holiday_date(key, day) VALUES (?, ?)", arguments: [key, day]) }
    }

    /// A video playlist of `owner` whose entries name `items` in order.
    func playlist(_ id: UID, of owner: UID, items: [(item: UID, edition: UID?)]) throws {
        try execute(
            sql: "INSERT INTO playlist(id, account_id, name, kind, created_at, modified_at, station_owned)"
                + " VALUES (?, ?, 'Mix', 'video', 0, 0, 0)", arguments: [id, owner])
        for (index, entry) in items.enumerated() {
            try execute(
                sql: "INSERT INTO playlist_entry(id, playlist_id, item_id, rank, added_at, edition_id, created_at,"
                    + " modified_at) VALUES (?, ?, ?, ?, 0, ?, 0, 0)",
                arguments: [UID.new(), id, entry.item, "a\(index)", entry.edition])
        }
    }
}
