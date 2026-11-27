import Foundation
import GRDB
import RabbitEarsAPI

/// Replica rows as the generated types the views read, field for field as
/// the server's responses carry them for the same rows.
enum ReplicaRows {
    /// Movies, shows, seasons and episodes as listItems answers them, over
    /// `item i`; a read adds its own condition on `i`.
    static let itemSQL = """
        SELECT i.id, i.library_id, i.parent_id, i.kind, i.parsed_title, i.parsed_year, i.season_number,
            i.episode_number, i.added_at, i.kids_content, m.item_id IS NOT NULL AS described, m.provider, m.provider_id,
            m.status, m.title, m.overview, m.release_date, m.runtime_minutes, m.content_rating, m.poster_path,
            m.backdrop_path, m.fetched_at,
            (SELECT COUNT(*) > 0 AND COUNT(*) = COUNT(uf.missing_at) FROM item_file ux
                JOIN media_file uf ON uf.id = ux.media_file_id WHERE ux.item_id = i.id) AS unavailable
        FROM item i LEFT JOIN item_shown m ON m.item_id = i.id
        WHERE i.kind IN ('movie', 'show', 'season', 'episode')
        """

    /// The catalog items `condition` keeps, each with its genres.
    static func items(
        _ db: Database, _ condition: String, _ arguments: StatementArguments = []
    ) throws -> [Item] {
        let rows = try Row.fetchAll(db, sql: "\(itemSQL) AND \(condition)", arguments: arguments)
        let genres = try genres(db, of: rows.map { $0["id"] })
        return rows.compactMap { item($0, genres: genres[$0["id"]] ?? []) }
    }

    /// Nil for a kind this build does not know.
    static func item(_ row: Row, genres: [Genre]) -> Item? {
        guard let kind = ItemKind(rawValue: row["kind"]) else { return nil }
        let rating: String? = text(row["content_rating"])
        var item = Item(
            id: row["id"], libraryId: row["library_id"], parentId: row["parent_id"], kind: kind,
            parsedTitle: row["parsed_title"], parsedYear: row["parsed_year"], seasonNumber: row["season_number"],
            episodeNumber: row["episode_number"], metadata: row["described"] ? metadata(row) : nil, genres: genres,
            // The replica carries neither audit instant; nothing reads them.
            addedAt: instant(row["added_at"]), createdAt: instant(row["added_at"]),
            modifiedAt: instant(row["added_at"]),
            unavailable: row["unavailable"] ? true : nil)
        if kind == .movie || kind == .show {
            let override: Bool? = row["kids_content"]
            item.kidsContent = override ?? kidsRatings[kind, default: []].contains(rating ?? "")
            item.kidsContentOverride = override
        }
        return item
    }

    static func watchState(_ row: Row) -> WatchState {
        WatchState(
            itemId: row["item_id"], positionMs: row["position_ms"], editionId: row["edition_id"],
            watched: row["watched"], playCount: row["play_count"],
            lastPlayedAt: (row["last_played_at"] as Int64?).map(instant), changedAt: instant(row["changed_at"]))
    }

    static func person(_ row: Row) -> Person {
        Person(id: row["id"], name: row["name"], tmdbId: row["tmdb_id"], profilePath: text(row["profile_path"]))
    }

    /// The ratings that make a movie or show kids' content without an override, as the server's item.KidsRatings.
    private static let kidsRatings: [ItemKind: [String]] = [.movie: ["G"], .show: ["TV-Y", "TV-Y7", "TV-G"]]

    private static func metadata(_ row: Row) -> Components.Schemas.ItemMetadata {
        .init(
            provider: text(row["provider"]).flatMap(Components.Schemas.ItemMetadata.ProviderPayload.init),
            providerId: row["provider_id"],
            status: .init(rawValue: row["status"]) ?? .unmatched, title: text(row["title"]),
            overview: text(row["overview"]), releaseDate: day(row["release_date"]),
            runtimeMinutes: row["runtime_minutes"], contentRating: text(row["content_rating"]),
            posterPath: text(row["poster_path"]), backdropPath: text(row["backdrop_path"]),
            fetchedAt: (row["fetched_at"] as Int64?).map(instant))
    }

    /// Each item's genres by name, as the server reads them.
    private static func genres(_ db: Database, of ids: [UID]) throws -> [UID: [Genre]] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT ig.item_id, g.id, g.name, g.tmdb_id FROM genre g JOIN item_genre_shown ig ON ig.genre_id = g.id
                WHERE ig.item_id IN (SELECT unhex(value, '-') FROM json_each(?)) ORDER BY g.name
                """, arguments: [json(ids)])
        return Dictionary(grouping: rows) { $0["item_id"] as UID }
            .mapValues { $0.map { Genre(id: $0["id"], name: $0["name"], tmdbId: $0["tmdb_id"]) } }
    }

    /// The argument for `<id column> IN (SELECT unhex(value, '-') FROM json_each(?))`,
    /// the one way to bind a list of ids: a JSON array of their strings.
    /// Text compared with a BLOB id matches nothing, so the unhex is required.
    static func json(_ ids: some Sequence<UID>) -> String {
        "[" + ids.map { "\"\($0)\"" }.joined(separator: ",") + "]"
    }

    /// An empty text is absent, as the server leaves it out.
    private static func text(_ value: String?) -> String? { value?.isEmpty == false ? value : nil }

    /// A release date the server sends only when it reads as a calendar day.
    private static func day(_ value: String?) -> String? {
        let style = Date.ISO8601FormatStyle().year().month().day()
        guard let value, let date = try? style.parse(value), style.format(date) == value else { return nil }
        return value
    }

    /// The replica's instants are Unix milliseconds.
    static func instant(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }
}
