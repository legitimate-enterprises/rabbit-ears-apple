import Foundation
import GRDB
import RabbitEarsAPI

/// The music listings as the server's item.Repo pages them (Artists,
/// Albums, Songs, Letters) over the replica's music views, for one profile:
/// what profile_item lets it hear, counted clean while it is a kid.
enum MusicRows {
    /// item.MusicFilter: nil is no constraint, and `sort` nil is the listing's default.
    struct Filter {
        var artistId: Int64?
        var albumId: Int64?
        var genreId: Int64?
        var id: Int64?
        var letter: String?
        var query: String?
        var sort: String?
        var limit = 100
        var offset = 0
        /// A limit that reads every row.
        static let all = Int.max - 1

        /// Those of `sql`'s named parameters, as SQLite takes no others.
        func arguments(_ profile: Int64, for sql: String) -> StatementArguments {
            let all: [String: (any DatabaseValueConvertible)?] = [
                "me": profile, "artist": artistId, "album": albumId, "genre": genreId, "id": id, "letter": letter,
                "q": query, "limit": limit, "offset": offset,
            ]
            return StatementArguments(all.filter { sql.contains(":\($0.key)") })
        }
    }

    static func artists(_ db: Database, _ profile: Int64, _ filter: Filter) throws -> ([MusicArtist], Int?) {
        let by = "\(sortKey("a")), a.id"
        let rows = try page(
            db, profile, filter,
            """
            SELECT a.id, a.library_id, a.parsed_title, a.sort_title, a.added_at,
                CASE WHEN k.mode THEN m.clean_album_count ELSE m.album_count END AS album_count,
                CASE WHEN k.mode THEN m.clean_song_count ELSE m.song_count END AS song_count
            """ + " \(artistsFrom(filter)) ORDER BY \(order(filter, "a", by))")
        let extras = try extras(db, rows.0)
        return (rows.0.map { artist($0, extras[$0["id"]]) }, rows.1)
    }

    /// An artist row: id, library_id, parsed_title, sort_title, added_at, album_count, song_count.
    static func artist(_ row: Row, _ extras: Extras?) -> MusicArtist {
        let sortTitle: String? = row["sort_title"]
        return MusicArtist(
            id: row["id"], libraryId: row["library_id"], name: row["parsed_title"],
            sortName: sortTitle?.isEmpty == false ? sortTitle! : row["parsed_title"],
            albumCount: row["album_count"], songCount: row["song_count"], overview: extras?.overview,
            genres: extras?.genres ?? [], musicBrainzId: extras?.mbid, addedAt: ReplicaRows.instant(row["added_at"]))
    }

    static func countArtists(_ db: Database, _ profile: Int64, _ filter: Filter) throws -> Int {
        try count(db, profile, filter, artistsFrom(filter))
    }

    /// Without `lastPlayedAt`: the profile's plays are not in the replica.
    static func albums(_ db: Database, _ profile: Int64, _ filter: Filter) throws -> ([MusicAlbum], Int?) {
        let by =
            [
                "artist": "\(sortKey("ar")), al.parsed_year, \(sortKey("al")), al.id",
                "year": "al.parsed_year IS NULL, al.parsed_year DESC, \(sortKey("al")), al.id",
                "added": "al.added_at DESC, al.id DESC",
            ][filter.sort ?? ""] ?? "\(sortKey("al")), al.id"
        let rows = try page(
            db, profile, filter,
            """
            SELECT al.id, al.library_id, al.parent_id, al.parsed_title, al.parsed_year, al.added_at, m.artist_name,
                CASE WHEN k.mode THEN m.clean_song_count ELSE m.song_count END AS song_count,
                CASE WHEN k.mode THEN m.clean_duration_ms ELSE m.duration_ms END AS duration_ms, m.lossless
            """ + " \(albumsFrom(filter)) ORDER BY \(order(filter, "al", by))")
        let extras = try extras(db, rows.0)
        return (rows.0.map { album($0, extras[$0["id"]]) }, rows.1)
    }

    /// An album row: id, library_id, parent_id, parsed_title, parsed_year, added_at, artist_name, song_count,
    /// duration_ms, lossless.
    static func album(_ row: Row, _ extras: Extras?) -> MusicAlbum {
        MusicAlbum(
            id: row["id"], libraryId: row["library_id"], artistId: row["parent_id"], artistName: row["artist_name"],
            title: row["parsed_title"], year: row["parsed_year"], songCount: row["song_count"],
            durationMs: row["duration_ms"], lossless: row["lossless"], overview: extras?.overview,
            genres: extras?.genres ?? [], musicBrainzId: extras?.mbid, addedAt: ReplicaRows.instant(row["added_at"]))
    }

    static func countAlbums(_ db: Database, _ profile: Int64, _ filter: Filter) throws -> Int {
        try count(db, profile, filter, albumsFrom(filter))
    }

    /// With an album and no sort, in disc then track order. "popular" reads
    /// plays the replica does not hold, and is not served here.
    static func songs(_ db: Database, _ profile: Int64, _ filter: Filter) throws -> ([MusicSong], Int?) {
        let track = "COALESCE(s.disc_number, 1), s.track_number IS NULL, s.track_number, \(sortKey("s")), s.id"
        let by =
            [
                "title": "\(sortKey("s")), s.id",
                "artist": "COALESCE(pa.sort_title, pa.parsed_title, ar.sort_title, ar.parsed_title) COLLATE NOCASE, "
                    + "\(sortKey("al")), al.id, \(track)",
                "album": "\(sortKey("al")), al.id, \(track)",
                "added": "s.added_at DESC, s.id DESC",
            ][filter.sort ?? ""] ?? (filter.albumId != nil ? track : "\(sortKey("s")), s.id")
        let rows = try page(
            db, profile, filter,
            "SELECT \(songColumns) \(songsFrom(filter)) ORDER BY \(order(filter, "s", by))")
        return (rows.0.map(song), rows.1)
    }

    /// The columns a song row maps from, `s` the song's item and `m` its music_song.
    static let songColumns = """
        s.id, s.library_id, s.parent_id, s.parsed_title, s.disc_number, s.track_number, m.album_title,
            m.album_artist_id, m.performer_id, m.artist_name, m.duration_ms, m.year, m.codec, m.unavailable
        """

    static func song(_ row: Row) -> MusicSong {
        let codec: String? = row["codec"]
        return MusicSong(
            id: row["id"], libraryId: row["library_id"], albumId: row["parent_id"],
            albumTitle: row["album_title"], albumArtistId: row["album_artist_id"],
            artistId: row["performer_id"], artistName: row["artist_name"], title: row["parsed_title"],
            discNumber: row["disc_number"], trackNumber: row["track_number"], durationMs: row["duration_ms"],
            year: row["year"], codec: codec?.isEmpty == false ? codec : nil, lossless: lossless(codec ?? ""),
            unavailable: (row["unavailable"] as Bool) ? true : nil)
    }

    static func countSongs(_ db: Database, _ profile: Int64, _ filter: Filter) throws -> Int {
        try count(db, profile, filter, songsFrom(filter))
    }

    /// How many albums or artists (`kind`) the profile hears under each letter, A to Z then #.
    static func letters(_ db: Database, _ profile: Int64, kind: String) throws -> [MusicLetterCount] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT \(letterOf("i")) AS letter, COUNT(*) AS n FROM item i
                WHERE i.kind = ? AND i.id IN (SELECT item_id FROM profile_item WHERE account_id = ?) GROUP BY letter
                """, arguments: [kind, profile]
        )
        .map { MusicLetterCount(letter: $0["letter"], count: $0["n"]) }
        .sorted { ($0.letter == "#" ? 1 : 0, $0.letter) < ($1.letter == "#" ? 1 : 0, $1.letter) }
    }

    /// The genres the profile hears something of in a music library, as listGenres answers each library's.
    static func genres(_ db: Database, _ profile: Int64) throws -> [Genre] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT DISTINCT g.id, g.name, g.tmdb_id FROM genre g JOIN item_genre_shown ig ON ig.genre_id = g.id
                    JOIN item i ON i.id = ig.item_id JOIN library l ON l.id = i.library_id
                WHERE l.kind = 'music' AND i.id IN (SELECT item_id FROM profile_item WHERE account_id = ?)
                """, arguments: [profile]
        ).map { Genre(id: $0["id"], name: $0["name"], tmdbId: $0["tmdb_id"]) }
    }

    /// mediafile.Lossless.
    static func lossless(_ codec: String) -> Bool {
        ["flac", "alac", "wavpack"].contains(codec) || codec.hasPrefix("pcm_")
    }

    private static func artistsFrom(_ filter: Filter) -> String {
        """
        FROM item a JOIN music_artist m ON m.item_id = a.id JOIN profile_audience k ON k.account_id = :me
        WHERE a.kind = 'artist' AND \(common("a", "a"))
        """
    }

    private static func albumsFrom(_ filter: Filter) -> String {
        """
        FROM item al JOIN music_album m ON m.item_id = al.id JOIN item ar ON ar.id = al.parent_id
            JOIN profile_audience k ON k.account_id = :me
        WHERE al.kind = 'album' AND (:artist IS NULL OR al.parent_id = :artist) AND \(common("al", "al"))
        """
    }

    private static func songsFrom(_ filter: Filter) -> String {
        """
        FROM item s JOIN music_song m ON m.item_id = s.id JOIN item al ON al.id = s.parent_id
            JOIN item ar ON ar.id = al.parent_id LEFT JOIN item pa ON pa.id = s.artist_id
        WHERE s.kind = 'song' AND (:artist IS NULL OR al.parent_id = :artist OR s.artist_id = :artist)
            AND (:album IS NULL OR s.parent_id = :album) AND \(common("s", "al"))
        """
    }

    /// The server's common over `alias`: genre on it or on `album`; letter; query; id; and what the profile hears.
    private static func common(_ alias: String, _ album: String) -> String {
        """
        \(alias).id IN (SELECT item_id FROM profile_item WHERE account_id = :me)
            AND (:genre IS NULL OR EXISTS (SELECT 1 FROM item_genre_shown ig
                WHERE ig.item_id IN (\(alias).id, \(album).id) AND ig.genre_id = :genre))
            AND (:letter IS NULL OR \(letterOf(alias)) = :letter)
            AND (:q IS NULL OR instr(lower(\(alias).parsed_title), lower(:q)) > 0)
            AND (:id IS NULL OR \(alias).id = :id)
        """
    }

    private static func sortKey(_ alias: String) -> String {
        "COALESCE(\(alias).sort_title, \(alias).parsed_title) COLLATE NOCASE"
    }

    private static func letterOf(_ alias: String) -> String {
        let first = "upper(substr(COALESCE(\(alias).sort_title, \(alias).parsed_title), 1, 1))"
        return "CASE WHEN \(first) BETWEEN 'A' AND 'Z' THEN \(first) ELSE '#' END"
    }

    /// A query's prefix matches first unless a sort was asked for.
    private static func order(_ filter: Filter, _ alias: String, _ by: String) -> String {
        filter.query != nil && filter.sort == nil ? "instr(lower(\(alias).parsed_title), lower(:q)) != 1, \(by)" : by
    }

    /// One page, and where the next starts when there is more.
    private static func page(_ db: Database, _ profile: Int64, _ filter: Filter, _ query: String) throws -> (
        [Row], Int?
    ) {
        var asked = filter
        asked.limit += 1
        let sql = "\(query) LIMIT :limit OFFSET :offset"
        let rows = try Row.fetchAll(db, sql: sql, arguments: asked.arguments(profile, for: sql))
        guard rows.count > filter.limit else { return (rows, nil) }
        return (Array(rows.prefix(filter.limit)), filter.offset + filter.limit)
    }

    private static func count(_ db: Database, _ profile: Int64, _ filter: Filter, _ from: String) throws -> Int {
        let sql = "SELECT COUNT(*) \(from)"
        return try Int.fetchOne(db, sql: sql, arguments: filter.arguments(profile, for: sql)) ?? 0
    }

    struct Extras {
        var overview: String?
        var mbid: String?
        var genres: [Genre] = []
    }

    /// The provider facts and genres the server adds to artists and albums, by item.
    static func extras(_ db: Database, _ rows: [Row]) throws -> [Int64: Extras] {
        let ids = "[\(rows.map { String($0["id"] as Int64) }.joined(separator: ","))]"
        var out: [Int64: Extras] = [:]
        for row in try Row.fetchAll(
            db,
            sql: """
                SELECT item_id, overview, status, external_id FROM item_shown
                WHERE item_id IN (SELECT value FROM json_each(?))
                """, arguments: [ids])
        {
            let overview: String? = row["overview"]
            let external: String? = row["external_id"]
            out[row["item_id"]] = Extras(
                overview: overview?.isEmpty == false ? overview : nil,
                mbid: (row["status"] as String?) == "matched" && external?.isEmpty == false ? external : nil)
        }
        for row in try Row.fetchAll(
            db,
            sql: """
                SELECT ig.item_id, g.id, g.name, g.tmdb_id FROM genre g JOIN item_genre_shown ig ON ig.genre_id = g.id
                WHERE ig.item_id IN (SELECT value FROM json_each(?)) ORDER BY g.name
                """, arguments: [ids])
        {
            out[row["item_id"], default: Extras()].genres.append(
                Genre(id: row["id"], name: row["name"], tmdbId: row["tmdb_id"]))
        }
        return out
    }
}
