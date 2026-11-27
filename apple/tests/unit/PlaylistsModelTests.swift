import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

extension Fixtures {
    /// A playlist the profile owns, or with `ownerName` one shared with it at `access`.
    static func playlist(
        _ id: Int64, _ name: String, kind: String = "music", count: Int = 0, durationMs: Int64 = 0,
        access: String = "owner", ownerName: String? = nil, shared: Bool? = nil
    ) -> String {
        #"{"id":\#(id),"profileId":1,"name":"\#(name)","kind":"\#(kind)","itemCount":\#(count),"#
            + #""access":"\#(access)","# + (shared.map { #""shared":\#($0),"# } ?? "")
            + (ownerName.map { #""ownerName":"\#($0)","# } ?? "")
            + #""durationMs":\#(durationMs),"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}"#
    }

    static func share(
        _ profileId: Int64, _ name: String, access: String = "read", kind: String = "adult", household: Int64? = nil
    ) -> String {
        #"{"playlistId":3,"profileId":\#(profileId),"name":"\#(name)","kind":"\#(kind)","access":"\#(access)","#
            + (household.map { #""householdId":\#($0),"# } ?? "") + #""createdAt":"2026-01-01T00:00:00Z"}"#
    }

    /// An entry of `kind` whose object, such as `"item":{…}`, is `objects`.
    static func entry(
        _ id: Int64, playlist: Int64 = 3, position: Int, kind: String, itemId: Int64, objects: String,
        count: Int = 1, durationMs: Int64 = 0
    ) -> String {
        #"{"id":\#(id),"playlistId":\#(playlist),"position":\#(position),"itemId":\#(itemId),"#
            + #""kind":"\#(kind)","itemCount":\#(count),"durationMs":\#(durationMs),\#(objects),"#
            + #""addedAt":"2026-01-01T00:00:00Z"}"#
    }

    static func entry(_ id: Int64, playlist: Int64 = 3, position: Int, collection: Int64, count: Int = 3) -> String {
        #"{"id":\#(id),"playlistId":\#(playlist),"position":\#(position),"collectionId":\#(collection),"#
            + #""kind":"collection","itemCount":\#(count),"durationMs":0,"#
            + #""collection":\#(Fixtures.collection(collection, "Comet saga", source: "tmdb", count: count)),"#
            + #""addedAt":"2026-01-01T00:00:00Z"}"#
    }

    static func entry(_ id: Int64, playlist: Int64 = 3, position: Int, song item: Int64) -> String {
        entry(
            id, playlist: playlist, position: position, kind: "song", itemId: item,
            objects: #""song":\#(Fixtures.song(item, "Song \(item)"))"#)
    }

    static func row(entry: Int64, song id: Int64) -> String {
        #"{"entryId":\#(entry),"itemId":\#(id),"kind":"song","song":\#(Fixtures.song(id, "Song \(id)"))}"#
    }

    static func row(entry: Int64, item id: Int64, kind: String = "episode", edition: String = "") -> String {
        #"{"entryId":\#(entry),"itemId":\#(id),"kind":"\#(kind)","item":\#(Fixtures.item(id, kind, "Item \(id)"))"#
            + #"\#(edition)}"#
    }
}

@MainActor
final class PlaylistsModelTests: XCTestCase {
    var synced: SyncedReplica!
    var transport: RoutingTransport { synced.transport }
    var model: PlaylistsModel!

    /// Avery (1) owns Sunday drive (3, music) and Movie night (4, movies);
    /// Ann (9), of another household, shares Theirs (5) with Avery to read
    /// and Ours (6) with household 7 to write; Avery's station plays its own
    /// playlist (8), which no list shows; Ann's Other (7) reaches no one here.
    override func setUp() async throws {
        synced = try SyncedReplica { db in
            try db.account(1, "Avery")
            try db.account(2, "Kit", kind: "kid", movies: "PG")
            try db.card(1, "Avery", household: 7)
            try db.card(9, "Ann")
            try db.playlist(3, "Sunday drive", kind: "music", played: 1_800_000_000_000)
            try db.playlist(4, "Movie night")
            try db.playlist(5, "Theirs", owner: 9)
            try db.playlist(6, "Ours", owner: 9, kind: "tv")
            try db.playlist(7, "Other", owner: 9)
            try db.playlist(8, "Channel's own", station: true)
            try db.share(5, with: 1, "read")
            try db.share(5, with: 2, "read")
            try db.householdShare(6, with: 7, "write")
            try db.share(6, with: 2, "write")
            try db.share(4, with: 2, "read")
        }
        addTeardownBlock { [synced] in await synced?.remove() }
        model = synced.playlists()
        await model.load()
    }

    func testLoadsTheProfilesOwnAndThoseReachingItByName() {
        XCTAssertEqual(model.playlists.map(\.name), ["Movie night", "Ours", "Sunday drive", "Theirs"])
        XCTAssertEqual(model.playlists(.music).map(\.id), [3])
        XCTAssertEqual(model.playlists(.movies).map(\.id), [4, 5])
        XCTAssertEqual(model.playlists(.tv).map(\.id), [6])
        XCTAssertEqual(model.playlists.map(\.access), [.owner, .write, .owner, .read])
        XCTAssertEqual(model.playlists.map(\.ownerName), [nil, "Ann", nil, "Ann"])
        XCTAssertEqual(model.playlists.map(\.isShared), [true, true, false, true], "Movie night is shared with Kit")
        XCTAssertEqual(model.playlists.map(\.profileId), [1, 9, 1, 9])
        XCTAssertEqual(model.playlists[2].lastPlayedAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(model.playlists[0].createdAt, Date(timeIntervalSince1970: 1))
        XCTAssertEqual(model.playlists[0].updatedAt, Date(timeIntervalSince1970: 2))
        XCTAssertNil(model.error)
    }

    func testAKidReadsWhatIsSharedWithItAndNeverWrites() async {
        let kid = synced.playlists(2, adult: false)
        await kid.load()
        XCTAssertEqual(kid.playlists.map(\.name), ["Movie night", "Ours", "Theirs"])
        XCTAssertEqual(kid.playlists.map(\.access), [.read, .read, .read], "a kid reads whatever its share says")
        XCTAssertEqual(kid.playlists.map(\.ownerName), ["Avery", "Ann", "Ann"])
    }

    func testTotalsArtAndImageCountOnlyWhatTheProfileMaySee() async throws {
        try await synced.replica.write { db in
            try db.item(20, "movie", "Dune", rating: "PG-13")
            try db.item(21, "movie", "Arrival", rating: "PG", year: 2016)
            try db.item(22, "movie", "Coco", rating: "G", year: 2010)
            try db.edition(120, of: 20, ms: 9_960_000)
            try db.edition(121, of: 21, ms: 6_960_000)
            try db.edition(122, of: 22, ms: 6_300_000)
            try db.collection(30, "Night picks")
            try db.collect(22, in: 30)
            try db.collect(21, in: 30)
            try db.entry(40, in: 4, item: 20, rank: "a1")
            try db.entry(41, in: 4, collection: 30, rank: "a0")
            try db.cover(60, on: 4)
            try db.cover(61, on: 3, item: 99)
        }
        await model.load()
        let night = try XCTUnwrap(model.playlists.first { $0.id == 4 })
        XCTAssertEqual(night.itemCount, 3)
        XCTAssertEqual(night.durationMs, 23_220_000)
        XCTAssertEqual(night.artItemId, 22, "the collection, ranked first, gives its first movie by release order")
        XCTAssertEqual(night.imageUrl, "/api/v1/profiles/1/playlists/4/image?v=60")
        XCTAssertNil(
            model.playlists.first { $0.id == 3 }?.imageUrl, "a title's art shows only while the title is in it")

        let kid = synced.playlists(2, adult: false)
        await kid.load()
        let seen = try XCTUnwrap(kid.playlists.first { $0.id == 4 })
        XCTAssertEqual(seen.itemCount, 2, "Dune is above a PG ceiling")
        XCTAssertEqual(seen.durationMs, 13_260_000)
        XCTAssertEqual(seen.imageUrl, "/api/v1/profiles/2/playlists/4/image?v=60")
    }

    func testCreateGoesToTheServerThenCatchesUp() async throws {
        transport.routes["POST /profiles/1/playlists"] = (.created, Fixtures.playlist(10, "Road trip", kind: "tv"))
        let blank = await model.create(name: "   ", kind: .tv)
        XCTAssertNil(blank)
        let made = await model.create(name: " Road trip ", kind: .tv)
        XCTAssertEqual(made?.id, 10)
        let sent = transport.json(.post, "/profiles/1/playlists")
        XCTAssertEqual(sent?["name"] as? String, "Road trip")
        XCTAssertEqual(sent?["kind"] as? String, "tv")
        XCTAssertTrue(synced.caughtUp, "the new rows come by sync")
        let queued = try synced.queued()
        XCTAssertEqual(queued, [])
    }

    func testRenameAndDeleteAreQueuedAndShowAtOnce() async throws {
        let night = try XCTUnwrap(model.playlists.first { $0.id == 4 })
        await model.rename(night, to: "  Late night ")
        XCTAssertEqual(model.playlists.first { $0.id == 4 }?.name, "Late night")
        XCTAssertEqual(try synced.lastBody()?["name"] as? String, "Late night")
        XCTAssertEqual(try synced.lastBody()?["kind"] as? String, "movies")
        XCTAssertEqual(try synced.lastTouched(), ["playlist 4"])

        let deleted = await model.delete(night)
        XCTAssertTrue(deleted)
        XCTAssertEqual(model.playlists.map(\.id), [6, 3, 5])
        let queued = try synced.queued()
        XCTAssertEqual(
            queued,
            ["replacePlaylist PUT /profiles/1/playlists/4", "deletePlaylist DELETE /profiles/1/playlists/4"])
        XCTAssertTrue(transport.sent.isEmpty, "nothing goes until the queue flushes")
    }

    func testAddsGoToTheServerThenCatchUp() async throws {
        transport.routes["POST /profiles/1/playlists/3/entries"] = (.created, Fixtures.entry(32, position: 0, song: 9))
        transport.routes["POST /profiles/1/playlists/4/entries"] = (
            .created, Fixtures.entry(40, playlist: 4, position: 0, collection: 6)
        )
        transport.routes["POST /profiles/1/playlists/9/entries/batch"] = (.noContent, "")
        let added = await model.add(9, to: 3, at: 0)
        XCTAssertTrue(added)
        let sent = transport.json(.post, "/profiles/1/playlists/3/entries")
        XCTAssertEqual(sent?["itemId"] as? Int, 9)
        XCTAssertEqual(sent?["position"] as? Int, 0)
        XCTAssertTrue(synced.caughtUp)

        let collection = await model.add(collection: 6, to: 4)
        XCTAssertTrue(collection)
        let body = try XCTUnwrap(transport.json(.post, "/profiles/1/playlists/4/entries"))
        XCTAssertEqual(body["collectionId"] as? Int, 6)
        XCTAssertNil(body["itemId"])

        let batch = await model.add([101, 100], to: 9)
        XCTAssertTrue(batch)
        let entries = transport.json(.post, "/profiles/1/playlists/9/entries/batch")?["entries"] as? [[String: Any]]
        XCTAssertEqual(entries?.compactMap { $0["itemId"] as? Int64 }, [101, 100])
        XCTAssertNil(model.error)
    }

    func testARefusedAddSaysWhy() async {
        transport.routes["POST /profiles/1/playlists/4/entries"] = (
            .badRequest, Fixtures.error("bad_request", "A song can't go in a movies playlist.")
        )
        let added = await model.add(9, to: 4)
        XCTAssertFalse(added)
        XCTAssertEqual(model.error, "A song can't go in a movies playlist.")
    }

    func testAVideoQueueWalksThePlayOrderAndStopsAtTheEnd() throws {
        let rows = [
            Fixtures.row(entry: 1, item: 20), Fixtures.row(entry: 2, item: 21), Fixtures.row(entry: 2, item: 22),
        ]
        .map { Fixtures.decode($0, as: PlayOrderRow.self) }
        let queue = try XCTUnwrap(VideoQueue(rows, start: try XCTUnwrap(rows.start(of: 2)), playlistId: 3))
        XCTAssertEqual(queue.current.id, 21)
        XCTAssertEqual(queue.playlistId, 3)
        let next = try XCTUnwrap(queue.next)
        XCTAssertEqual(next.current.id, 22)
        XCTAssertNil(next.next)
        XCTAssertNil(VideoQueue([], start: 0, playlistId: 3))
    }

    func testEachQueuedRowPlaysItsOwnEditionAndNamesItWhenThereIsAChoice() throws {
        let rows = [
            Fixtures.row(entry: 1, item: 20, kind: "movie", edition: #","editionId":6,"editionName":"Extended""#),
            Fixtures.row(entry: 2, item: 21, kind: "movie", edition: #","editionId":8"#),
            Fixtures.row(entry: 3, item: 22),
        ]
        .map { Fixtures.decode($0, as: PlayOrderRow.self) }
        let queue = try XCTUnwrap(VideoQueue(rows, start: 0, playlistId: 3))
        XCTAssertEqual(queue.editionId, 6)
        XCTAssertEqual(PlaylistText.named("Item 20", edition: queue.editionName), "Item 20 · Extended")
        let second = try XCTUnwrap(queue.next)
        XCTAssertEqual(second.editionId, 8)
        XCTAssertEqual(PlaylistText.named("Item 21", edition: second.editionName), "Item 21")
        XCTAssertNil(second.next?.editionId)
    }

    func testAnAddCarriesTheChosenEdition() async throws {
        transport.routes["POST /profiles/1/playlists/4/entries"] = (.created, Fixtures.entry(40, position: 0, song: 9))
        let added = await model.add(20, to: 4, edition: 6)
        XCTAssertTrue(added)
        XCTAssertEqual(transport.json(.post, "/profiles/1/playlists/4/entries")?["editionId"] as? Int, 6)
        let plain = await model.add(21, to: 4)
        XCTAssertTrue(plain)
        XCTAssertNil(transport.json(.post, "/profiles/1/playlists/4/entries")?["editionId"])
    }

    func testAnAddRefusedForWantOfAnEditionAsksWhichThenAddsIt() async throws {
        try await synced.replica.write { db in
            try db.item(20, "movie", "Ferrous Tide")
            try db.edition(5, of: 20, ms: 6_000_000, tag: "Standard")
            try db.edition(6, of: 20, ms: 7_000_000, tag: "Extended")
        }
        transport.respond = { sent in
            guard sent.method == .post, sent.path == "/profiles/1/playlists/4/entries" else { return nil }
            return sent.body.contains("editionId")
                ? (.created, Fixtures.entry(40, position: 0, song: 9)) : (.badRequest, Fixtures.fieldError("editionId"))
        }
        let first = await model.add(20, to: 4, at: 2)
        XCTAssertFalse(first)
        XCTAssertNil(model.error, "a question, not a failure")
        let question = try XCTUnwrap(model.editionQuestion)
        XCTAssertEqual(question.editions.map(\.name), ["Standard", "Extended"])
        XCTAssertFalse(transport.paths(.get).contains("/items/20"), "the replica's editions")

        let added = await model.answer(question, with: question.editions[1])
        XCTAssertTrue(added)
        XCTAssertNil(model.editionQuestion)
        let sent = try XCTUnwrap(transport.json(.post, "/profiles/1/playlists/4/entries"))
        XCTAssertEqual(sent["itemId"] as? Int, 20)
        XCTAssertEqual(sent["editionId"] as? Int, 6)
        XCTAssertEqual(sent["position"] as? Int, 2)
    }

    func testAnotherRefusalIsAnErrorNotAQuestion() async {
        transport.routes["POST /profiles/1/playlists/4/entries"] = (.badRequest, Fixtures.fieldError("position"))
        let added = await model.add(20, to: 4)
        XCTAssertFalse(added)
        XCTAssertNil(model.editionQuestion)
        XCTAssertEqual(model.error, "invalid request")
        XCTAssertFalse(transport.paths(.get).contains("/items/20"))
    }

    func testAnEntryOfOneOfSeveralEditionsNamesIt() {
        let movie: PlaylistEntry = Fixtures.decode(
            Fixtures.entry(
                1, position: 0, kind: "movie", itemId: 9,
                objects: #""item":\#(Fixtures.item(9, "movie", "Ferrous Tide")),"editionId":6,"editionName":"Extended""#
            ))
        XCTAssertEqual(PlaylistText.title(movie), "Ferrous Tide · Extended")
    }

    func testAPlaylistTakesItsKindFromTheItem() {
        XCTAssertEqual(PlaylistKind(holding: .movie), .movies)
        XCTAssertEqual(PlaylistKind(holding: .show), .tv)
        XCTAssertEqual(PlaylistKind(holding: .season), .tv)
        XCTAssertEqual(PlaylistKind(holding: .episode), .tv)
    }

    func testSummariesCountWhatThePlayOrderPlays() {
        func summary(_ kind: String, _ count: Int, _ ms: Int64) -> String {
            PlaylistText.summary(Fixtures.decode(Fixtures.playlist(1, "P", kind: kind, count: count, durationMs: ms)))
        }
        XCTAssertEqual(summary("movies", 3, 22_200_000), "3 movies · 6h 10m")
        XCTAssertEqual(summary("tv", 1, 1_800_000), "1 episode · 30m")
        XCTAssertEqual(summary("music", 48, 10_920_000), "48 songs · 3h 2m")
    }

    func testAContainerEntryIsOneRowSayingWhatItStandsFor() {
        func entry(_ kind: String, _ objects: String, count: Int = 1, ms: Int64 = 0) -> PlaylistEntry {
            Fixtures.decode(
                Fixtures.entry(1, position: 0, kind: kind, itemId: 9, objects: objects, count: count, durationMs: ms))
        }
        let show = #""show":\#(Fixtures.item(70, "show", "Severance"))"#
        let movie = entry("movie", #""item":\#(Fixtures.item(9, "movie", "Dune"))"#, ms: 9_960_000)
        XCTAssertEqual(PlaylistText.title(movie), "Dune")
        XCTAssertEqual(PlaylistText.detail(movie), "2h 46m")
        XCTAssertEqual(movie.artId, 9)

        let series = entry("show", #""item":\#(Fixtures.item(9, "show", "Severance"))"#, count: 12)
        XCTAssertEqual(PlaylistText.detail(series), "12 episodes")
        let season = entry(
            "season", #""item":\#(Fixtures.item(9, "season", "Season 2", parent: 70)),\#(show)"#, count: 10)
        XCTAssertEqual(PlaylistText.title(season), "Season 2")
        XCTAssertEqual(PlaylistText.detail(season), "Severance · 10 episodes")
        let episode = entry(
            "episode", #""item":\#(Fixtures.item(9, "episode", "Hello", parent: 71, season: 1, episode: 3)),\#(show)"#)
        XCTAssertEqual(PlaylistText.detail(episode), "Severance · S1 E3")

        let artist = entry("artist", #""artist":\#(Fixtures.artist)"#, count: 112)
        XCTAssertEqual(PlaylistText.title(artist), "Radiohead")
        XCTAssertEqual(PlaylistText.detail(artist), "112 songs")
        let album = entry("album", #""album":\#(Fixtures.album(50, "In Rainbows"))"#, count: 9)
        XCTAssertEqual(PlaylistText.title(album), "In Rainbows")
        XCTAssertEqual(PlaylistText.detail(album), "Radiohead · 9 songs")
        let song = entry("song", #""song":\#(Fixtures.song(9, "Nude", album: 50))"#)
        XCTAssertEqual(PlaylistText.title(song), "Nude")
        XCTAssertEqual(PlaylistText.detail(song), "Radiohead · In Rainbows")
        XCTAssertEqual(song.artId, 50, "a song's art is its album's")

        let collection: PlaylistEntry = Fixtures.decode(Fixtures.entry(1, position: 0, collection: 6, count: 3))
        XCTAssertEqual(PlaylistText.title(collection), "Comet saga")
        XCTAssertEqual(PlaylistText.detail(collection), "3 movies")
        XCTAssertEqual(collection.artId, 6, "a collection's art is its own")
    }
}

@MainActor
final class PlaylistStationTests: XCTestCase {
    func testDeletingAPlaylistAStationPlaysIsRefusedAtOnce() async throws {
        let synced = try SyncedReplica { db in
            try db.account(1, "Avery")
            try db.playlist(3, "Sunday drive")
            try db.station(5, of: 1, playing: 3)
        }
        addTeardownBlock { await synced.remove() }
        let model = synced.playlists()
        await model.load()
        let deleted = await model.delete(model.playlists[0])
        XCTAssertFalse(deleted)
        XCTAssertEqual(
            model.error, "A station plays this playlist. Delete the station or give it another playlist first.")
        XCTAssertEqual(model.playlists.map(\.id), [3])
        let queued = try synced.queued()
        XCTAssertEqual(queued, [])
    }
}
