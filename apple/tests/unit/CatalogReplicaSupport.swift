import Foundation
import GRDB

@testable import RabbitEarsKit

/// Rows of sync schema 1 for editions, collections, credits, occasions and playlists.
extension Database {
    /// An edition of `item`, `tag` nil for an untagged cut.
    func edition(_ id: Int64, of item: Int64, tag: String? = nil, runtimeMs: Int64? = nil) throws {
        try execute(sql: "INSERT INTO edition VALUES (?, ?, ?, ?)", arguments: [id, item, tag, runtimeMs])
    }

    /// A file of `edition`, with a video track of `width` x `height` unless both are nil.
    func file(
        _ id: Int64, in edition: Int64, width: Int? = nil, height: Int? = nil, hdr: String? = nil,
        size: Int64 = 1000, durationMs: Int64? = nil, missing: Bool = false
    ) throws {
        try execute(
            sql: "INSERT INTO media_file(id, size_bytes, duration_ms, missing_at) VALUES (?, ?, ?, ?)",
            arguments: [id, size, durationMs, missing ? 1 : nil])
        try execute(sql: "INSERT INTO edition_file VALUES (?, ?)", arguments: [edition, id])
        if width != nil || height != nil {
            try execute(
                sql: """
                    INSERT INTO track(id, media_file_id, stream_index, kind, codec, width, height, hdr_format)
                    VALUES (?, ?, 0, 'video', 'h264', ?, ?, ?)
                    """, arguments: [id * 10, id, width, height, hdr])
        }
    }

    /// One edition holding one file on disk, for an item that only needs to be playable.
    func playable(_ item: Int64, missing: Bool = false) throws {
        try edition(item * 100, of: item)
        try file(item * 100, in: item * 100, missing: missing)
    }

    /// A collection holding `movies` in order; `positions` sets a hand order.
    func collection(
        _ id: Int64, _ name: String, source: String = "custom", household: Int64? = 7, movies: [Int64],
        positions: Bool = false
    ) throws {
        try execute(
            sql: "INSERT INTO collection(id, source, household_id, tmdb_id, name, created_at, updated_at) "
                + "VALUES (?, ?, ?, ?, ?, 0, 0)",
            arguments: [id, source, source == "tmdb" ? nil : household, source == "tmdb" ? id * 10 : nil, name])
        for (index, movie) in movies.enumerated() {
            try execute(
                sql: "INSERT INTO collection_movie VALUES (?, ?, ?)", arguments: [id, movie, positions ? index : nil])
        }
    }

    func credit(
        _ id: Int64, item: Int64, person: Int64, kind: String, position: Int, character: String? = nil,
        job: String? = nil
    ) throws {
        try execute(
            sql: "INSERT INTO credit(id, item_id, person_id, kind, character, job, position)"
                + " VALUES (?, ?, ?, ?, ?, ?, ?)",
            arguments: [id, item, person, kind, character, job, position])
    }

    func person(_ id: Int64, _ name: String, tmdb: Int64? = nil, profilePath: String? = nil) throws {
        try execute(sql: "INSERT INTO person VALUES (?, ?, ?, ?)", arguments: [id, tmdb, name, profilePath])
    }

    /// An occasion anchored to a holiday key, or else to month and day, with titles added by hand.
    func occasion(
        _ id: Int64, _ name: String, holiday: String? = nil, month: Int? = nil, day: Int? = nil, before: Int,
        after: Int, members: [Int64] = [], phrases: [String] = [], colors: [String]? = nil
    ) throws {
        try execute(
            sql: "INSERT INTO occasion VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            arguments: [id, name, holiday, month, day, before, after, colors?[0], colors?[1], colors?[2]])
        for member in members { try execute(sql: "INSERT INTO occasion_item VALUES (?, ?)", arguments: [id, member]) }
        for phrase in phrases {
            try execute(sql: "INSERT INTO occasion_phrase VALUES (?, ?)", arguments: [id, phrase])
        }
    }

    func holiday(_ key: String, on days: [String]) throws {
        for day in days { try execute(sql: "INSERT INTO holiday_date VALUES (?, ?)", arguments: [key, day]) }
    }

    /// A video playlist of `owner` whose entries name `items` in order.
    func playlist(_ id: Int64, of owner: Int64, items: [(item: Int64, edition: Int64?)]) throws {
        try execute(
            sql: "INSERT INTO playlist VALUES (?, ?, 'Mix', 'video', NULL, 0, 0, 0)", arguments: [id, owner])
        for (index, entry) in items.enumerated() {
            try execute(
                sql: "INSERT INTO playlist_entry(id, playlist_id, item_id, rank, added_at, edition_id) "
                    + "VALUES (?, ?, ?, ?, 0, ?)",
                arguments: [id * 100 + Int64(index), id, entry.item, "a\(index)", entry.edition])
        }
    }
}
