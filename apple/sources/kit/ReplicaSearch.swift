import GRDB

/// Search over the replica as the server's search matches: a case-insensitive
/// substring of a movie's or show's parsed or shown title, or of an
/// episode's shown title, or of a person's name; those starting with the
/// query first, then by title. The full-text tables live in the replica
/// file only, built when a snapshot is adopted and kept by each diff. They
/// narrow the candidates; the server's own `instr(lower(…))` test decides,
/// so non-ASCII case folds as on the server.
public enum ReplicaSearch {
    /// Trigrams match any substring of three characters or more.
    private static let shortest = 3

    private static let indexItems = """
        INSERT INTO fts_item(rowid, parsed_title, title)
        SELECT i.id, i.parsed_title, s.title FROM item i LEFT JOIN item_shown s ON s.item_id = i.id
        WHERE i.kind IN ('movie', 'show', 'episode')
        """

    public static func build(in db: Database) throws {
        try db.execute(
            sql: """
                CREATE VIRTUAL TABLE fts_item USING fts5(parsed_title, title, tokenize = 'trigram',
                    content = '', contentless_delete = 1);
                CREATE VIRTUAL TABLE fts_person USING fts5(name, tokenize = 'trigram',
                    content = '', contentless_delete = 1);
                \(indexItems);
                INSERT INTO fts_person(rowid, name) SELECT id, name FROM person;
                """)
    }

    /// Re-indexes after a diff. `changed` holds, by table, the first key
    /// part of each row written or deleted; a changed `server_info` can
    /// change every shown title.
    public static func update(in db: Database, changed: [String: [DatabaseValue]]) throws {
        if changed["server_info"] != nil {
            try db.execute(sql: "DELETE FROM fts_item; \(indexItems)")
        } else {
            for id in Set((changed["item"] ?? []) + (changed["item_metadata"] ?? [])) {
                try db.execute(sql: "DELETE FROM fts_item WHERE rowid = ?", arguments: [id])
                try db.execute(sql: "\(indexItems) AND i.id = ?", arguments: [id])
            }
        }
        for id in Set(changed["person"] ?? []) {
            try db.execute(sql: "DELETE FROM fts_person WHERE rowid = ?", arguments: [id])
            try db.execute(
                sql: "INSERT INTO fts_person(rowid, name) SELECT id, name FROM person WHERE id = ?", arguments: [id])
        }
    }

    /// Movies, shows and episodes, in the server's order for search.
    public static func items(matching query: String, in db: Database) throws -> [Int64] {
        try Int64.fetchAll(
            db,
            sql: """
                SELECT i.id FROM item i LEFT JOIN item_shown s ON s.item_id = i.id
                WHERE \(candidates("fts_item", "i.id", query)) (:q = ''
                    OR i.kind IN ('movie', 'show') AND instr(lower(i.parsed_title), lower(:q)) > 0
                    OR i.kind IN ('movie', 'show', 'episode') AND instr(lower(s.title), lower(:q)) > 0)
                ORDER BY NOT (instr(lower(i.parsed_title), lower(:q)) = 1
                        OR instr(lower(COALESCE(s.title, '')), lower(:q)) = 1),
                    i.parsed_title COLLATE NOCASE, i.season_number, i.episode_number, i.id
                """, arguments: arguments(query))
    }

    public static func people(matching query: String, in db: Database) throws -> [Int64] {
        try Int64.fetchAll(
            db,
            sql: """
                SELECT p.id FROM person p
                WHERE \(candidates("fts_person", "p.id", query)) instr(lower(p.name), lower(:q)) > 0
                ORDER BY instr(lower(p.name), lower(:q)) != 1, p.name COLLATE NOCASE, p.id
                """, arguments: arguments(query))
    }

    /// The rows `table` finds for the query, as a condition on `id`; none
    /// for a query too short to hold a trigram, which every row then meets.
    private static func candidates(_ table: String, _ id: String, _ query: String) -> String {
        query.count < shortest ? "" : "\(id) IN (SELECT rowid FROM \(table) WHERE \(table) MATCH :match) AND"
    }

    /// The query, and as `match` one FTS5 string, which a trigram table reads as a substring.
    private static func arguments(_ query: String) -> StatementArguments {
        guard query.count >= shortest else { return ["q": query] }
        return ["q": query, "match": "\"\(query.replacingOccurrences(of: "\"", with: "\"\""))\""]
    }
}
