import Foundation
import GRDB
import RabbitEarsAPI

@testable import RabbitEarsKit

/// Music and YouTube rows of sync schema 1, in library 3 (music) and 4
/// (YouTube) as the scanner files them. A file's edition, media file and
/// first track share the item's id.
extension Database {
    func artist(_ id: UID, _ name: String, sort: String? = nil, added: String = "2026-01-01T00:00:00Z") throws {
        try execute(
            sql: """
                INSERT INTO item(id, library_id, kind, parsed_title, sort_title, added_at)
                VALUES (?, \(sqlID(3)), 'artist', ?, ?, ?)
                """,
            arguments: [id, name, sort, Self.ms(added)])
    }

    func album(
        _ id: UID, _ title: String, artist: UID, year: Int? = nil, sort: String? = nil,
        added: String = "2026-01-01T00:00:00Z"
    ) throws {
        try execute(
            sql: """
                INSERT INTO item(id, library_id, parent_id, kind, parsed_title, parsed_year, sort_title, added_at)
                VALUES (?, \(sqlID(3)), ?, 'album', ?, ?, ?, ?)
                """, arguments: [id, artist, title, year, sort, Self.ms(added)])
    }

    /// A song with one file of `durationMs` whose audio is `codec`; no codec, no file.
    func song(
        _ id: UID, _ title: String, album: UID, disc: Int? = nil, track: Int? = nil, performer: UID? = nil,
        year: Int? = nil, explicit: Bool = false, durationMs: Int64 = 200_000, codec: String? = "flac",
        missing: Bool = false, added: String = "2026-01-01T00:00:00Z"
    ) throws {
        try execute(
            sql: """
                INSERT INTO item(id, library_id, parent_id, kind, parsed_title, parsed_year, disc_number, track_number,
                    artist_id, added_at, explicit) VALUES (?, \(sqlID(3)), ?, 'song', ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [id, album, title, year, disc, track, performer, Self.ms(added), explicit])
        if let codec { try file(id, durationMs: durationMs, kind: "audio", codec: codec, missing: missing) }
    }

    /// Provider facts as the server shows them: MusicBrainz's, matched, unless `status` says otherwise.
    func described(_ id: UID, overview: String? = nil, mbid: String? = nil, status: String = "matched") throws {
        try execute(
            sql: """
                INSERT INTO item_metadata(item_id, source, provider, status, overview, external_id)
                VALUES (?, 'remote', 'musicbrainz', ?, ?, ?)
                """, arguments: [id, status, overview, mbid])
    }

    func genre(_ id: UID, _ name: String, on item: UID) throws {
        try execute(sql: "INSERT OR IGNORE INTO genre(id, name) VALUES (?, ?)", arguments: [id, name])
        try execute(sql: "INSERT INTO item_genre VALUES (?, ?, 'remote')", arguments: [item, id])
    }

    func file(
        _ id: UID, durationMs: Int64, kind: String, codec: String, height: Int? = nil, missing: Bool = false
    ) throws {
        try execute(sql: "INSERT INTO edition(id, item_id) VALUES (?, ?)", arguments: [id, id])
        try execute(sql: "INSERT INTO edition_file VALUES (?, ?)", arguments: [id, id])
        try execute(
            sql: "INSERT INTO media_file(id, size_bytes, duration_ms, missing_at) VALUES (?, 1, ?, ?)",
            arguments: [id, durationMs, missing ? 1 : nil])
        try execute(
            sql: "INSERT INTO track(id, media_file_id, stream_index, kind, codec, height) VALUES (?, ?, 0, ?, ?, ?)",
            arguments: [id, id, kind, codec, height])
    }

    /// A channel of library 4; `kids` is its for-kids mark.
    func channel(
        _ id: UID, _ title: String, kids: Bool? = nil, external: String? = nil, overview: String? = nil,
        added: String = "2026-01-01T00:00:00Z"
    ) throws {
        try execute(
            sql: """
                INSERT INTO item(id, library_id, kind, parsed_title, added_at, kids_content)
                VALUES (?, \(sqlID(4)), 'channel', ?, ?, ?)
                """,
            arguments: [id, title, Self.ms(added), kids])
        try youTubeMetadata(id, external: external, overview: overview, published: nil)
    }

    /// A video with its local metadata, as the scanner reads it from its sidecar.
    func video(
        _ id: UID, _ title: String, channel: UID, published: String? = nil, external: String? = nil,
        overview: String? = nil, durationMs: Int64? = nil, height: Int? = nil, added: String = "2026-01-01T00:00:00Z"
    ) throws {
        try execute(
            sql: """
                INSERT INTO item(id, library_id, parent_id, kind, parsed_title, added_at)
                VALUES (?, \(sqlID(4)), ?, 'video', ?, ?)
                """,
            arguments: [id, channel, title, Self.ms(added)])
        try youTubeMetadata(id, external: external, overview: overview, published: published)
        if let durationMs { try file(id, durationMs: durationMs, kind: "video", codec: "h264", height: height) }
    }

    private func youTubeMetadata(_ id: UID, external: String?, overview: String?, published: String?) throws {
        try execute(
            sql: """
                INSERT INTO item_metadata(item_id, source, provider, status, overview, external_id, published_at)
                VALUES (?, 'local', 'youtube', 'matched', ?, ?, ?)
                """, arguments: [id, overview, external, published.map(Self.ms)])
    }

    /// Shows local metadata first, as a server reading YouTube's sidecars does.
    func preferLocal() throws {
        try execute(sql: "UPDATE server_info SET metadata_source = 'local', metadata_mode = 'preferred'")
    }
}
