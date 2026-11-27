import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

@MainActor
final class PlaylistEntriesTests: XCTestCase {
    var synced: SyncedReplica!
    var model: PlaylistsModel!

    /// Avery (1) owns Sunday drive (3, music) and Movie night (4, movies),
    /// shared with Kit (2), a kid under PG; Ann (9) shares Ours (6, tv) with
    /// household 7, and Other (7) with no one here.
    override func setUp() async throws {
        synced = try SyncedReplica { db in
            try db.account(1, "Avery")
            try db.account(2, "Kit", kind: "kid", movies: "PG")
            try db.card(9, "Ann")
            try db.playlist(3, "Sunday drive", kind: "music")
            try db.playlist(4, "Movie night")
            try db.playlist(6, "Ours", owner: 9, kind: "tv")
            try db.playlist(7, "Other", owner: 9)
            try db.householdShare(6, with: 7, "write")
            try db.share(4, with: 2, "read")
        }
        addTeardownBlock { [synced] in await synced?.remove() }
        model = synced.playlists()
    }

    /// An album, a song and an artist in Sunday drive; a tagged cut of Dune and
    /// TMDB's Comet saga in Movie night; an episode in Ours.
    private func fill() async throws {
        try await synced.replica.write { db in
            try db.library(2, "music")
            try db.item(20, "movie", "Dune", rating: "PG-13")
            try db.edition(120, of: 20, ms: 9_960_000)
            try db.edition(121, of: 20, ms: 10_800_000, tag: "Extended")
            try db.item(70, "show", "Severance", rating: "TV-MA")
            try db.item(71, "season", "Season 1", parent: 70, season: 1)
            try db.item(72, "episode", "Hello", parent: 71, season: 1, episode: 3)
            try db.edition(172, of: 72, ms: 3_000_000)
            try db.music(80, "artist", "Radiohead")
            try db.music(81, "album", "In Rainbows", parent: 80)
            try db.music(82, "song", "Nude", parent: 81)
            try db.edition(182, of: 82, ms: 255_000)
            try db.collection(30, "Comet saga", source: "tmdb")
            try db.item(23, "movie", "Comet", rating: "PG")
            try db.edition(123, of: 23, ms: 6_000_000)
            try db.collect(23, in: 30)
            try db.entry(40, in: 3, item: 82, rank: "a2")
            try db.entry(41, in: 3, item: 81, rank: "a0")
            try db.entry(42, in: 3, item: 80, rank: "a2")
            try db.entry(43, in: 4, item: 20, rank: "a1", edition: 121)
            try db.entry(44, in: 4, collection: 30, rank: "a0")
            try db.entry(45, in: 6, item: 72, rank: "a0", edition: 172)
        }
    }

    func testMusicEntriesComeInRankOrderEachAsTheServerFillsIt() async throws {
        try await fill()
        let musicRead = await model.entries(of: 3)
        let music = try XCTUnwrap(musicRead)
        XCTAssertEqual(music.map(\.id), [41, 40, 42], "equal ranks by id")
        XCTAssertEqual(music.map(\.position), [0, 1, 2])
        XCTAssertEqual(music.map(\.kind), [.album, .song, .artist])
        XCTAssertEqual(music[0].album?.title, "In Rainbows")
        XCTAssertEqual(music[0].album?.artistName, "Radiohead")
        XCTAssertEqual(music[0].album?.songCount, 1)
        XCTAssertEqual(music[1].song?.albumTitle, "In Rainbows")
        XCTAssertEqual(music[1].song?.durationMs, 255_000)
        XCTAssertEqual(music[2].artist?.albumCount, 1)
        XCTAssertEqual(music.map(\.itemCount), [1, 1, 1])
        XCTAssertEqual(music.map(\.durationMs), [255_000, 255_000, 255_000])
        XCTAssertEqual(music.map(\.rank), ["a0", "a2", "a2"])
    }

    func testMovieAndEpisodeEntriesCarryWhatTheyStandFor() async throws {
        try await fill()
        let moviesRead = await model.entries(of: 4)
        let movies = try XCTUnwrap(moviesRead)
        XCTAssertEqual(movies.map(\.id), [44, 43])
        XCTAssertEqual(movies[0].kind, .collection)
        XCTAssertEqual(movies[0].collection?.name, "Comet saga")
        XCTAssertEqual(movies[0].collection?.movieCount, 1)
        XCTAssertEqual(movies[0].collection?.customOrder, false)
        XCTAssertEqual(movies[1].item?.parsedTitle, "Dune")
        XCTAssertEqual(movies[1].editionId, 121)
        XCTAssertEqual(movies[1].editionName, "Extended")
        XCTAssertEqual(movies[1].durationMs, 10_800_000)

        let tvRead = await model.entries(of: 6)
        let tv = try XCTUnwrap(tvRead)
        XCTAssertEqual(tv.first?.item?.id, 72)
        XCTAssertEqual(tv.first?.show?.id, 70, "an episode carries its show")
        XCTAssertNil(tv.first?.editionName, "a lone edition goes unnamed")
    }

    func testAKidGetsOnlyTheEntriesStandingForWhatItMayPlay() async throws {
        try await fill()
        let kid = synced.playlists(2, adult: false)
        let narrowedRead = await kid.entries(of: 4)
        let narrowed = try XCTUnwrap(narrowedRead)
        XCTAssertEqual(narrowed.map(\.id), [44], "a kid gets only what stands for something it may play")
        XCTAssertEqual(narrowed.map(\.position), [0])
        let none = await kid.entries(of: 3)
        XCTAssertNil(none, "a playlist that does not reach the profile")
        XCTAssertNotNil(kid.error)
    }

    func testAnUntaggedCutAmongSeveralIsNamedByItsLength() async throws {
        try await synced.replica.write { db in
            try db.item(20, "movie", "Dune", rating: "PG-13")
            try db.edition(120, of: 20, ms: 9_960_000)
            try db.edition(121, of: 20, ms: 10_830_000)
            try db.entry(43, in: 4, item: 20, rank: "a1", edition: 121)
        }
        let entriesRead = await model.entries(of: 4)
        let entries = try XCTUnwrap(entriesRead)
        XCTAssertEqual(entries.first?.editionName, "181-minute cut")
    }

    func testAMoveIsRankedBetweenItsNewNeighboursAndQueued() async throws {
        try await synced.replica.write { db in
            for (number, rank) in [(40, "a0"), (41, "a1"), (42, "a1"), (43, "a3")] {
                try db.item(.n(20 + number), "movie", "Movie \(number)", rating: "PG")
                try db.entry(.n(number), in: 4, item: .n(20 + number), rank: rank)
            }
        }
        let entriesRead = await model.entries(of: 4)
        let entries = try XCTUnwrap(entriesRead)
        await model.move(entries[3], to: 1)
        let body = try XCTUnwrap(try synced.lastBody())
        XCTAssertEqual(body["rank"] as? String, "a0V")
        XCTAssertNil(body["position"])
        XCTAssertEqual(body["itemId"] as? String, UID.n(63).description)
        XCTAssertEqual(try synced.lastTouched(), ["playlist_entry \(UID.n(43))"])
        let moved = await model.entries(of: 4)?.first { $0.id == 43 }
        XCTAssertGreaterThan(try XCTUnwrap(moved).modifiedAt, entries[3].modifiedAt, "as the server stamps a move")
        XCTAssertEqual(moved?.modifiedBy, 1)
        let order1 = await model.entries(of: 4)?.map(\.id)
        XCTAssertEqual(order1, [40, 43, 41, 42])

        await model.move(entries[0], to: 2)
        XCTAssertEqual(try synced.lastBody()?["rank"] as? String, "a2", "between equal ranks lands after both")
        let order2 = await model.entries(of: 4)?.map(\.id)
        XCTAssertEqual(order2, [43, 41, 42, 40])

        await model.remove(entries[1])
        let order3 = await model.entries(of: 4)?.map(\.id)
        XCTAssertEqual(order3, [43, 42, 40])
        let queued = try synced.queued()
        let path = "/profiles/\(UID.n(1))/playlists/\(UID.n(4))/entries"
        XCTAssertEqual(
            queued,
            [
                "replacePlaylistEntry PUT \(path)/\(UID.n(43))",
                "replacePlaylistEntry PUT \(path)/\(UID.n(40))",
                "removePlaylistEntry DELETE \(path)/\(UID.n(41))",
            ])
        XCTAssertNil(model.error)
    }

    func testThePlayOrderExpandsEntriesAsTheServerDoes() async throws {
        try await synced.replica.write { db in
            try db.library(2, "music")
            try db.music(80, "artist", "Radiohead")
            try db.music(81, "album", "In Rainbows", parent: 80)
            try db.music(82, "song", "Nude", parent: 81)
            try db.music(83, "song", "Reckoner", parent: 81)
            try db.execute(
                sql: "UPDATE item SET track_number = 2 WHERE id = \(sqlID(82)); "
                    + "UPDATE item SET track_number = 1 WHERE id = \(sqlID(83))")
            try db.edition(182, of: 82, ms: 255_000)
            try db.edition(183, of: 83, ms: 290_000)
            try db.music(85, "artist", "Nobody")
            try db.entry(40, in: 3, item: 82, rank: "a1")
            try db.entry(41, in: 3, item: 81, rank: "a0")
            try db.entry(42, in: 3, item: 85, rank: "a2")
        }
        let rowsRead = await model.playOrder(of: 3)
        let rows = try XCTUnwrap(rowsRead)
        XCTAssertEqual(rows.map(\.itemId), [83, 82, 82], "the album by track, then the song")
        XCTAssertEqual(rows.map(\.entryId), [41, 41, 40])
        XCTAssertEqual(rows.songs.map(\.title), ["Reckoner", "Nude", "Nude"])
        XCTAssertEqual(rows.map(\.durationMs), [290_000, 255_000, 255_000])
        XCTAssertEqual(rows.map(\.editionId), [183, 182, 182])
        XCTAssertEqual(rows.start(of: 40), 2)
        XCTAssertNil(rows.start(of: 42), "an entry that stands for nothing now")
    }

    /// The server takes at most 2,000 entries a call, so a larger batch goes
    /// as consecutive calls, each touching its own rows, ranked on from the one before.
    func testABatchOverWhatOneCallTakesIsQueuedAsConsecutiveCalls() async throws {
        let ids = (0...2000).map { UID.n(1000 + $0) }
        try await synced.replica.write { db in
            for id in ids { try db.item(id, "movie", "Movie") }
        }
        let added = await model.add(ids, to: 4)
        XCTAssertTrue(added)
        XCTAssertNil(model.error)

        let path = "/profiles/\(UID.n(1))/playlists/\(UID.n(4))/entries/batch"
        XCTAssertEqual(try synced.queued(), ["addPlaylistEntries POST \(path)", "addPlaylistEntries POST \(path)"])
        let sent: [Int] = try await synced.read(
            "SELECT json_array_length(CAST(body AS TEXT), '$.entries') FROM queue.action ORDER BY seq")
        XCTAssertEqual(sent, [2000, 1])
        let touched: [Int] = try await synced.read(
            """
            SELECT count(*) FROM queue.action a JOIN queue.action_touch t ON t.action = a.seq
            JOIN json_each(CAST(a.body AS TEXT), '$.entries') e ON json_extract(e.value, '$.id') = t.key1
            GROUP BY a.seq ORDER BY a.seq
            """)
        XCTAssertEqual(touched, [2000, 1], "each call touches the rows it sends")
        let read = await model.entries(of: 4)
        let entries = try XCTUnwrap(read)
        XCTAssertEqual(entries.compactMap(\.itemId), ids)
        let ranks = entries.compactMap(\.rank)
        XCTAssertEqual(ranks.count, ids.count)
        XCTAssertTrue(zip(ranks, ranks.dropFirst()).allSatisfy { $0 < $1 }, "ascending across the calls")
    }

    func testAnUnreadablePlayOrderIsNil() async {
        let read = await model.playOrder(of: 7)
        XCTAssertNil(read)
        XCTAssertNotNil(model.error)
    }
}
