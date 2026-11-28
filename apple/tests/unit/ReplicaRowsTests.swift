import Foundation
import GRDB
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// The fixture schema is the server's, and the mappers build from its rows
/// what the server's REST answers carry for the same rows.
final class ReplicaRowsTests: XCTestCase {
    var fixture: ReplicaFixture!

    override func setUp() { fixture = ReplicaFixture() }
    override func tearDown() { fixture.remove() }

    func testTheV1SchemaRunsOnTheBundledSQLiteAndEveryViewReads() throws {
        let db = try DatabaseQueue()
        let views = try db.write { db in
            try db.execute(sql: ReplicaSchema.v1)
            try db.execute(sql: ReplicaSchema.sample)
            return try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'view' ORDER BY name")
        }
        XCTAssertEqual(
            views,
            [
                "credit_shown", "item_file", "item_genre_shown", "item_keyword_shown", "item_shown", "kids_item",
                "membership", "metadata_setting", "music_album", "music_artist", "music_song", "occasion_member",
                "playlist_reach", "playlist_row", "profile_art", "profile_audience", "profile_collection_art",
                "profile_item",
                "profile_item_open",
                "profile_station",
            ])
        for view in views {
            XCTAssertNoThrow(try db.read { try Row.fetchAll($0, sql: "SELECT * FROM \(view) LIMIT 1") }, view)
        }
        let shown = try db.read {
            try Int.fetchOne($0, sql: "SELECT count(*) FROM profile_item WHERE account_id = \(sqlID(103))")
        }
        XCTAssertGreaterThan(shown ?? 0, 0, "the sample's views find rows")
        XCTAssertEqual(try db.read { try String.fetchOne($0, sql: "SELECT sqlite_version()") }, "3.54.1")
    }

    /// Each row carries the art addresses profile_art names for the profile reading it: an episode its show's,
    /// a song, an album and an artist the album's, a video its channel's, a collection and a playlist their first
    /// movie's.
    func testEveryRowCarriesTheArtTheReplicaNamesForItsProfile() async throws {
        let replica = try fixture.v1 { db in
            try db.account(1, "Avery")
            try db.account(2, "Robin", kind: "kid")
            try db.item(10, "movie", "Dune", rating: "G")
            try db.item(11, "show", "Andor", rating: "TV-G")
            try db.item(12, "season", "Season 1", parent: 11, season: 1)
            try db.item(13, "episode", "One", parent: 12, season: 1, episode: 1)
            try db.art(10, poster: "dune", backdrop: "dune-wide")
            try db.art(11, poster: "andor")
            try db.collection(9, "Dunes", movies: [10])
            try db.playlist(8, "Mix")
            try db.entry(80, in: 8, item: 10, rank: "a0")
            try db.artist(40, "Radiohead")
            try db.album(50, "In Rainbows", artist: 40)
            try db.song(5, "Bodysnatchers", album: 50)
            try db.art(50, poster: "rainbows")
            try db.channel(60, "Tech")
            try db.video(61, "Unboxing", channel: 60)
            try db.art(60, poster: "tech")
        }
        let (dune, andor, rainbows, tech) = (
            ArtworkTests.address("dune"), ArtworkTests.address("andor"), ArtworkTests.address("rainbows"),
            ArtworkTests.address("tech")
        )
        let found = try await replica.read { db in
            try ReplicaRows.items(db, ids: [10, 13], for: 1)
        }
        XCTAssertEqual(found.map(\.posterUrl), [dune, andor])
        XCTAssertEqual(found.map(\.backdropUrl), [ArtworkTests.address("dune-wide", store: "w1280"), nil])
        let (albums, artists, songs, channels, videos, collections, playlists) = try await replica.read { db in
            (
                try MusicRows.albums(db, 1, .init()).0, try MusicRows.artists(db, 1, .init()).0,
                try MusicRows.songs(db, 1, .init()).0,
                try YouTubeRows.channels(db, 1), try YouTubeRows.videos(db, 1, .init()).0,
                try CollectionRows.list(db, profile: 1), try PlaylistRows.playlists(db, profile: 1)
            )
        }
        XCTAssertEqual(albums.map(\.posterUrl), [rainbows])
        XCTAssertEqual(artists.map(\.posterUrl), [rainbows])
        XCTAssertEqual(songs.map(\.posterUrl), [rainbows])
        XCTAssertEqual(channels.map(\.posterUrl), [tech])
        XCTAssertEqual(videos.map(\.posterUrl), [tech])
        XCTAssertEqual(videos.map(\.channelPosterUrl), [tech])
        XCTAssertEqual(collections.map(\.posterUrl), [dune])
        XCTAssertEqual(playlists.map(\.posterUrl), [dune])
        let entries = try await replica.read { try PlaylistRows.entries($0, profile: 1, playlist: 8) }
        XCTAssertEqual(entries.map(\.item?.posterUrl), [dune])
    }

    /// A poster in the server's own store shows by its file name, as the server shows it to all but an admin;
    /// TMDB's path is shown whole, and so is the address the image is at.
    func testAnItemsStoredArtShowsByItsFileNameAndTMDBsWhole() async throws {
        let replica = try fixture.v1 { db in
            try db.account(1, "Avery")
            try db.preferLocal()
            try db.item(10, "movie", "Dune")
            try db.item(11, "movie", "Heat")
            try db.art(10, poster: "dune", backdrop: "dune-wide")
            try db.execute(
                sql: """
                    INSERT INTO item_metadata(item_id, source, status, poster_path, backdrop_path)
                    VALUES (?, 'local', 'matched', 'local/heat.jpg', 'local/heat-wide.jpg')
                    """, arguments: [UID.n(11)])
        }
        let found = try await replica.read { try ReplicaRows.items($0, ids: [10, 11], for: 1) }
        XCTAssertEqual(found.map(\.metadata?.posterPath), ["/dune.jpg", "heat.jpg"])
        XCTAssertEqual(found.map(\.metadata?.backdropPath), ["/dune-wide.jpg", "heat-wide.jpg"])
        XCTAssertEqual(found.last?.posterUrl, "/api/v2/artwork/local/heat.jpg")
    }

    /// A playlist or collection is smart while a smart_list row names it, and a station while its playlist is.
    func testAListIsSmartWhileASmartListNamesIt() async throws {
        let replica = try fixture.v1 { db in
            try db.account(1, "Avery")
            try db.item(10, "movie", "Dune")
            try db.playlist(7, "Picked")
            try db.playlist(8, "Ruled")
            try db.collection(5, "Picked", movies: [10])
            try db.collection(6, "Ruled", movies: [10])
            try db.station(3, of: 1, playing: 7)
            try db.station(4, of: 1, playing: 8)
            try db.execute(
                sql: """
                    UPDATE station SET household_id = ?, visibility = 'private', timing = 'continuous', shuffled = 0,
                        created_at = 0, modified_at = 0
                    """, arguments: [UID.n(7)])
            try db.execute(
                sql: """
                    INSERT INTO smart_list(id, playlist_id, collection_id, created_at) VALUES (?, ?, NULL, 0),
                        (?, NULL, ?, 0)
                    """, arguments: [UID.n(90), UID.n(8), UID.n(91), UID.n(6)])
        }
        let (playlists, collections, stations) = try await replica.read { db in
            (
                try PlaylistRows.playlists(db, profile: 1), try CollectionRows.list(db, profile: 1),
                try StationRows.stations(db, profile: 1, at: Date(), calendar: .current)
            )
        }
        XCTAssertEqual(playlists.map(\.name), ["Picked", "Ruled"])
        XCTAssertEqual(playlists.map(\.smart), [false, true])
        XCTAssertEqual(collections.map(\.smart), [false, true])
        XCTAssertEqual(stations.map(\.smart), [false, true])
    }

    private func items(_ replica: Replica, _ ids: [UID]) async throws -> [UID: Item] {
        let list = try await replica.read { db in
            try ReplicaRows.items(db, ids: ids, for: 103)
        }
        return Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }

    /// The replica keeps no instants of an item's row: both are its addedAt.
    private func item(_ fields: String, library: Int = 1, genres: String = "[]") -> Item {
        Fixtures.decode(
            #"{"libraryId":\#(jsonID(library)),"addedAt":"1970-01-01T00:00:00Z","createdAt":"1970-01-01T00:00:00Z","#
                + #""modifiedAt":"1970-01-01T00:00:00Z","genres":\#(genres),\#(fields)}"#)
    }

    /// The sample's server settings show local metadata first, then TMDB's.
    func testTheSamplesItemsReadAsTheServerAnswersThem() async throws {
        let replica = try fixture.v1(sample: true)
        let found = try await items(replica, [1, 2, 3, 8, 9, 11, 17])
        XCTAssertEqual(
            found[2],
            item(
                #""id":\#(jsonID(2)),"kind":"movie","parsedTitle":"PG Movie","sortTitle":"PG Movie","#
                    + #""kidsContent":false,"#
                    + #""metadata":{"provider":"tmdb","status":"unmatched","contentRating":"PG"}"#),
            "the rating is the local row's, the provider and status the remote row's")
        XCTAssertEqual(
            found[3],
            item(
                #""id":\#(jsonID(3)),"kind":"movie","parsedTitle":"PG-13 Movie","sortTitle":"PG-13 Movie","#
                    + #""kidsContent":false,"#
                    + #""metadata":{"status":"unmatched","contentRating":"PG-13"}"#))
        XCTAssertEqual(
            found[1],
            item(
                #""id":\#(jsonID(1)),"kind":"movie","parsedTitle":"G Movie","sortTitle":"G Movie","kidsContent":true,"#
                    + #""metadata":{"status":"unmatched","contentRating":"G"}"#,
                genres: #"[{"id":\#(jsonID(1)),"name":"Drama"}]"#))
        XCTAssertEqual(found[9]?.kidsContent, true, "rated R, marked for kids")
        XCTAssertEqual(found[9]?.kidsContentOverride, true)
        XCTAssertEqual(found[8]?.kidsContent, false, "rated G, marked not for kids")
        XCTAssertEqual(found[8]?.kidsContentOverride, false)
        XCTAssertEqual(found[17]?.kidsContent, true)
        XCTAssertEqual(
            found[11],
            item(#""id":\#(jsonID(11)),"parentId":\#(jsonID(10)),"kind":"season","parsedTitle":"Tots""#, library: 2),
            "only movies and shows say whether they are kids' content")
    }

    func testEveryFieldOfAnItemComesFromItsOwnColumn() async throws {
        let replica = try fixture.v1 { db in
            try db.execute(
                sql: """
                    INSERT INTO item(id, library_id, parent_id, kind, parsed_title, parsed_year, season_number,
                        episode_number, added_at, kids_content) VALUES
                        (\(sqlID(31)), \(sqlID(4)), \(sqlID(30)), 'episode', 'Dune Day', 2023, 2, 7, 1714521600250,
                            NULL),
                        (\(sqlID(32)), \(sqlID(4)), NULL, 'movie', 'Dune Two', 2024, NULL, NULL, 1714521600000, NULL),
                        (\(sqlID(33)), \(sqlID(4)), NULL, 'movie', 'Leap', NULL, NULL, NULL, 0, NULL);
                    INSERT INTO item_metadata(item_id, source, provider, provider_id, status, title, overview,
                        release_date, runtime_minutes, content_rating, poster_path, backdrop_path) VALUES
                        (\(sqlID(31)), 'remote', 'tmdb', 693134, 'matched', 'Arrakis', 'Sand.', '2024-02-27', 166,
                            'PG-13', '/p.jpg', '/b.jpg'),
                        (\(sqlID(32)), 'remote', 'tmdb', 5, 'matched', '', '', '2024', NULL, '', NULL, NULL),
                        (\(sqlID(33)), 'remote', 'tmdb', 6, 'matched', NULL, NULL, '2023-02-29', NULL, 'G', NULL, NULL);
                    INSERT INTO genre(id, name, tmdb_id) VALUES (\(sqlID(878)), 'Science Fiction', 878),
                        (\(sqlID(12)), 'adventure', NULL);
                    INSERT INTO item_genre(item_id, genre_id, source) VALUES (\(sqlID(31)), \(sqlID(878)), 'remote'),
                        (\(sqlID(31)), \(sqlID(12)), 'remote'), (\(sqlID(32)), \(sqlID(12)), 'local');
                    INSERT INTO edition(id, item_id) VALUES (\(sqlID(1)), \(sqlID(31))), (\(sqlID(2)), \(sqlID(32)));
                    INSERT INTO edition_file(edition_id, media_file_id) VALUES (\(sqlID(1)), \(sqlID(1))),
                        (\(sqlID(2)), \(sqlID(2))), (\(sqlID(2)), \(sqlID(3)));
                    INSERT INTO media_file(id, missing_at)
                        VALUES (\(sqlID(1)), 5), (\(sqlID(2)), 5), (\(sqlID(3)), NULL);
                    """)
        }
        let found = try await items(replica, [31, 32, 33])
        XCTAssertEqual(
            found[31],
            Fixtures.decode(
                #"{"id":\#(jsonID(31)),"libraryId":\#(jsonID(4)),"parentId":\#(jsonID(30)),"kind":"episode","#
                    + #""parsedTitle":"Dune Day","parsedYear":2023,"#
                    + #""seasonNumber":2,"episodeNumber":7,"addedAt":"2024-05-01T00:00:00.25Z","#
                    + #""createdAt":"2024-05-01T00:00:00.25Z","modifiedAt":"2024-05-01T00:00:00.25Z","#
                    + #""genres":[{"id":\#(jsonID(12)),"name":"adventure"},"#
                    + #"{"id":\#(jsonID(878)),"name":"Science Fiction","tmdbId":878}],"metadata":{"provider":"tmdb","#
                    + #""providerId":693134,"status":"matched","title":"Arrakis","overview":"Sand.","#
                    + #""releaseDate":"2024-02-27","runtimeMinutes":166,"contentRating":"PG-13","posterPath":"/p.jpg","#
                    + #""backdropPath":"/b.jpg"},"unavailable":true}"#, as: Item.self),
            "its only file is missing")
        XCTAssertNil(found[32]?.unavailable, "one of its files is there")
        XCTAssertEqual(
            found[32]?.metadata, .init(provider: .tmdb, providerId: 5, status: .matched),
            "empty text and a date that is not a day are left out")
        XCTAssertEqual(found[32]?.genres, [], "the remote row hides the local genres")
        XCTAssertEqual(found[32]?.kidsContent, false, "unrated is not kids' content")
        XCTAssertNil(found[33]?.metadata?.releaseDate, "no such day")
        XCTAssertEqual(found[33]?.kidsContent, true)
    }

    func testAWatchStateReadsAsTheServerAnswersIt() async throws {
        let replica = try fixture.v1(sample: true) { db in
            try db.execute(
                sql: "INSERT INTO watch_state VALUES (?, ?, 61000, 1, 3, 1777593600250, 1777680000000, ?)",
                arguments: [UID.n(101), UID.n(20), UID.n(6)])
        }
        let states = try await replica.read { db in
            try Row.fetchAll(
                db, sql: "SELECT * FROM watch_state WHERE account_id IN (?, ?) ORDER BY item_id",
                arguments: [UID.n(101), UID.n(103)]
            ).map(ReplicaRows.watchState)
        }
        XCTAssertEqual(
            states,
            [
                Fixtures.decode(
                    #"{"itemId":\#(jsonID(2)),"positionMs":7,"watched":false,"playCount":0,"#
                        + #""changedAt":"1970-01-01T00:00:00Z"}"#
                ),
                Fixtures.decode(
                    #"{"itemId":\#(jsonID(20)),"positionMs":61000,"editionId":\#(jsonID(6)),"watched":true,"#
                        + #""playCount":3,"#
                        + #""lastPlayedAt":"2026-05-01T00:00:00.25Z","changedAt":"2026-05-02T00:00:00Z"}"#),
            ])
    }
}

/// Test id `number` as a JSON string.
private func jsonID(_ number: Int) -> String { "\"\(UID.n(number))\"" }
