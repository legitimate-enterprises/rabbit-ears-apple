import Foundation
import GRDB
import HTTPTypes
import OpenAPIRuntime
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// Snapshots and change pages shaped as the server's: a few tables of the
/// v1 projection with their real keys and declared types, ids BLOB, among
/// them 2- and 3-part ones with text parts, server_info's integer key,
/// untyped columns and a reduced `item_shown`.
enum SyncFixture {
    static let schema = """
        CREATE TABLE server_info(id INTEGER PRIMARY KEY, name TEXT NOT NULL, metadata_source TEXT NOT NULL,
            metadata_mode TEXT NOT NULL);
        INSERT INTO server_info VALUES (1, 'Home', 'tmdb', 'remote');
        CREATE TABLE item(id BLOB PRIMARY KEY, library_id BLOB NOT NULL DEFAULT x'00000000000070008000000000000001',
            parent_id BLOB, kind TEXT NOT NULL, parsed_title TEXT NOT NULL, season_number INTEGER,
            episode_number INTEGER, sort_title TEXT, kids_content INTEGER);
        CREATE TABLE item_metadata(item_id BLOB NOT NULL, source TEXT NOT NULL, title TEXT, overview TEXT,
            PRIMARY KEY (item_id, source));
        CREATE TABLE item_genre(item_id BLOB NOT NULL, genre_id BLOB NOT NULL, source TEXT NOT NULL,
            PRIMARY KEY (item_id, genre_id, source));
        CREATE TABLE person(id BLOB PRIMARY KEY, name TEXT NOT NULL);
        CREATE TABLE occasion_phrase(occasion_id BLOB NOT NULL, phrase TEXT NOT NULL,
            PRIMARY KEY (occasion_id, phrase));
        CREATE TABLE account(id BLOB PRIMARY KEY, kind TEXT NOT NULL, name TEXT NOT NULL, has_pin, color TEXT);
        CREATE TABLE account_card(id BLOB PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL, color TEXT);
        CREATE TABLE watch_state(account_id BLOB NOT NULL, item_id BLOB NOT NULL, position_ms INTEGER NOT NULL,
            watched INTEGER NOT NULL, changed_at INTEGER NOT NULL, PRIMARY KEY (account_id, item_id));
        CREATE VIEW item_shown AS SELECT i.id AS item_id,
            CASE WHEN s.metadata_mode = 'local' THEN l.title ELSE COALESCE(r.title, l.title) END AS title
            FROM item i CROSS JOIN server_info s
            LEFT JOIN item_metadata l ON l.item_id = i.id AND l.source = 'local'
            LEFT JOIN item_metadata r ON r.item_id = i.id AND r.source = 'remote';
        """

    /// A snapshot file at `version` whose movies are `titles`, ids from UID.n(1), and `rows` run after.
    static func snapshot(in directory: URL, version: Int64, titles: [String] = [], rows: String = "") throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "\(UUID().uuidString).sqlite")
        try DatabaseQueue(path: file.path(percentEncoded: false)).write { db in
            try db.execute(sql: schema)
            try db.execute(
                sql: """
                    CREATE TABLE replica_meta(schema INTEGER NOT NULL, version INTEGER NOT NULL,
                        household_id BLOB NOT NULL);
                    INSERT INTO replica_meta VALUES (1, ?, \(sqlID(7)));
                    """, arguments: [version])
            for (index, title) in titles.enumerated() {
                try db.execute(
                    sql: "INSERT INTO item(id, kind, parsed_title) VALUES (?, 'movie', ?)",
                    arguments: [UID.n(index + 1), title])
            }
            if !rows.isEmpty { try db.execute(sql: rows) }
        }
        // A served file is read, never taken.
        try DatabaseQueue(path: file.path(percentEncoded: false)).writeWithoutTransaction {
            try $0.execute(sql: "PRAGMA journal_mode = DELETE")
        }
        return file
    }

    static func ranges(apiMin: String = "0.26.0", apiMax: String = "0.26.0", schemaMax: Int = 1) -> String {
        #"{"apiMin":"\#(apiMin)","apiMax":"\#(apiMax)","schemaMin":1,"schemaMax":\#(schemaMax)}"#
    }

    static func mode(_ mode: String, ranges: String = ranges()) -> String {
        #"{"mode":"\#(mode)","ranges":\#(ranges)}"#
    }

    /// UID.n(n) as a JSON string, for the id cells of a page.
    static func id(_ number: Int) -> String { "\"\(UID.n(number))\"" }

    /// A table's changed rows, its columns and rows each a JSON array literal.
    struct Table {
        let name: String
        let columns: String
        let rows: String

        init(_ name: String, _ columns: String, _ rows: String) {
            (self.name, self.columns, self.rows) = (name, columns, rows)
        }
    }

    /// `tombstones` as table to keys, a JSON array literal.
    static func diff(
        version: Int64, cursor: String? = nil, tables: [Table] = [],
        tombstones: [(String, String)] = [], ranges: String = ranges()
    ) -> String {
        let tables = tables.map { #"{"name":"\#($0.name)","columns":\#($0.columns),"rows":\#($0.rows)}"# }
        let tombstones = tombstones.map { #"{"table":"\#($0.0)","keys":\#($0.1)}"# }
        let cursor = cursor.map { #","cursor":"\#($0)""# } ?? ""
        return #"{"mode":"diff","ranges":\#(ranges),"version":\#(version)\#(cursor),"#
            + #""tables":[\#(tables.joined(separator: ","))],"tombstones":[\#(tombstones.joined(separator: ","))]}"#
    }
}

/// RoutingTransport records and routes, but answers text; a snapshot is
/// bytes, served here from `snapshot` once RoutingTransport has seen it.
final class SyncTransport: ClientTransport, @unchecked Sendable {
    let routes = RoutingTransport()
    var snapshot: URL?

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let answer = try await routes.send(request, body: body, baseURL: baseURL, operationID: operationID)
        guard request.path?.hasPrefix("/sync/snapshot") == true, let snapshot else { return answer }
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "application/vnd.sqlite3"
        return (response, HTTPBody(try Data(contentsOf: snapshot)))
    }
}

/// What the engine's callbacks saw, read back by the test.
actor Calls {
    private(set) var flushes = 0
    private(set) var queues: [[String]] = []
    private(set) var signOuts = 0

    func flushed(queue: [String] = []) {
        flushes += 1
        queues.append(queue)
    }

    func signedOut() { signOuts += 1 }
}

/// The waits a loop asked for; with `hold`, each lasts until cancelled.
actor Waits {
    private(set) var all: [Duration] = []

    func add(_ wait: Duration, hold: Bool = false) async {
        all.append(wait)
        if hold { try? await Task.sleep(for: .seconds(3600)) }
    }
}
