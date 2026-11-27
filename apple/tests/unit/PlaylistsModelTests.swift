import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

extension Fixtures {
    /// A playlist the profile owns, or with `ownerName` one shared with it at `access`.
    static func playlist(
        _ id: UID, _ name: String, kind: String = "music", count: Int = 0, durationMs: Int64 = 0,
        access: String = "owner", ownerName: String? = nil, shared: Bool? = nil
    ) -> String {
        #"{"id":"\#(id)","profileId":"\#(UID.n(1))","name":"\#(name)","kind":"\#(kind)","itemCount":\#(count),"#
            + #""access":"\#(access)","# + (shared.map { #""shared":\#($0),"# } ?? "")
            + (ownerName.map { #""ownerName":"\#($0)","# } ?? "")
            + #""durationMs":\#(durationMs),"createdAt":"2026-01-01T00:00:00Z","modifiedAt":"2026-01-01T00:00:00Z"}"#
    }

    static func share(
        _ profileId: UID, _ name: String, access: String = "read", kind: String = "adult", household: UID? = nil
    ) -> String {
        #"{"playlistId":"\#(UID.n(3))","profileId":"\#(profileId)","name":"\#(name)","kind":"\#(kind)","#
            + #""access":"\#(access)","# + (household.map { #""householdId":"\#($0)","# } ?? "")
            + #""createdAt":"2026-01-01T00:00:00Z"}"#
    }

    /// An entry of `kind` whose object, such as `"item":{…}`, is `objects`.
    static func entry(
        _ id: UID, playlist: UID = 3, position: Int, kind: String, itemId: UID, objects: String,
        count: Int = 1, durationMs: Int64 = 0
    ) -> String {
        #"{"id":"\#(id)","playlistId":"\#(playlist)","position":\#(position),"itemId":"\#(itemId)","#
            + #""kind":"\#(kind)","itemCount":\#(count),"durationMs":\#(durationMs),\#(objects),"#
            + #""addedAt":"2026-01-01T00:00:00Z","createdAt":"2026-01-01T00:00:00Z","#
            + #""modifiedAt":"2026-01-01T00:00:00Z"}"#
    }

    static func entry(_ id: UID, playlist: UID = 3, position: Int, collection: UID, count: Int = 3) -> String {
        #"{"id":"\#(id)","playlistId":"\#(playlist)","position":\#(position),"collectionId":"\#(collection)","#
            + #""kind":"collection","itemCount":\#(count),"durationMs":0,"#
            + #""collection":\#(Fixtures.collection(collection, "Comet saga", source: "tmdb", count: count)),"#
            + #""addedAt":"2026-01-01T00:00:00Z","createdAt":"2026-01-01T00:00:00Z","#
            + #""modifiedAt":"2026-01-01T00:00:00Z"}"#
    }

    static func entry(_ id: UID, playlist: UID = 3, position: Int, song item: UID) -> String {
        entry(
            id, playlist: playlist, position: position, kind: "song", itemId: item,
            objects: #""song":\#(Fixtures.song(item, "Song \(item)"))"#)
    }

    static func row(entry: UID, song id: UID) -> String {
        #"{"entryId":"\#(entry)","itemId":"\#(id)","kind":"song","song":\#(Fixtures.song(id, "Song \(id)"))}"#
    }

    static func row(entry: UID, item id: UID, kind: String = "episode", edition: String = "") -> String {
        #"{"entryId":"\#(entry)","itemId":"\#(id)","kind":"\#(kind)","#
            + #""item":\#(Fixtures.item(id, kind, "Item \(id)"))\#(edition)}"#
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
        XCTAssertEqual(model.playlists.map(\.createdBy), [1, 9, 1, 9])
        XCTAssertEqual(model.playlists.map(\.modifiedBy), [1, 9, 1, 9])
        XCTAssertEqual(model.playlists[2].lastPlayedAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(model.playlists[0].createdAt, Date(timeIntervalSince1970: 1))
        XCTAssertEqual(model.playlists[0].modifiedAt, Date(timeIntervalSince1970: 2))
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
        XCTAssertEqual(night.imageUrl, "/api/v2/profiles/\(UID.n(1))/playlists/\(UID.n(4))/image?v=\(UID.n(60))")
        XCTAssertNil(
            model.playlists.first { $0.id == 3 }?.imageUrl, "a title's art shows only while the title is in it")

        let kid = synced.playlists(2, adult: false)
        await kid.load()
        let seen = try XCTUnwrap(kid.playlists.first { $0.id == 4 })
        XCTAssertEqual(seen.itemCount, 2, "Dune is above a PG ceiling")
        XCTAssertEqual(seen.durationMs, 13_260_000)
        XCTAssertEqual(seen.imageUrl, "/api/v2/profiles/\(UID.n(2))/playlists/\(UID.n(4))/image?v=\(UID.n(60))")
    }

    func testACreateIsQueuedAndShowsAtOnceUnderItsClientId() async throws {
        transport.failure = URLError(.notConnectedToInternet)
        let blank = await model.create(name: "   ", kind: .tv)
        XCTAssertNil(blank)
        let created = await model.create(name: " Road trip ", kind: .tv)
        let made = try XCTUnwrap(created)
        XCTAssertNil(model.error)
        XCTAssertEqual(made.name, "Road trip")
        XCTAssertEqual(made.kind, .tv)
        XCTAssertEqual(made.access, .owner)
        XCTAssertEqual(made.profileId, 1)
        XCTAssertEqual(made.createdAt, made.modifiedAt)
        XCTAssertEqual(made.createdBy, 1)
        XCTAssertEqual(made.modifiedBy, 1)
        XCTAssertEqual(model.playlists(.tv).map(\.id), [6, made.id], "by name")
        let stored: [String] = try await synced.read("SELECT typeof(id) FROM playlist WHERE name = 'Road trip'")
        XCTAssertEqual(stored, ["blob"])

        let body = try XCTUnwrap(try synced.lastBody())
        XCTAssertEqual(body["id"] as? String, made.id.description)
        XCTAssertEqual(body["name"] as? String, "Road trip")
        XCTAssertEqual(body["kind"] as? String, "tv")
        XCTAssertEqual(try synced.lastTouched(), ["playlist \(made.id)"])
        XCTAssertEqual(try synced.queued(), ["createPlaylist POST /profiles/\(UID.n(1))/playlists"])
        XCTAssertTrue(transport.sent.isEmpty, "nothing goes until the queue flushes")
    }

    func testRenameAndDeleteAreQueuedAndShowAtOnce() async throws {
        let night = try XCTUnwrap(model.playlists.first { $0.id == 4 })
        await model.rename(night, to: "  Late night ")
        let renamed = try XCTUnwrap(model.playlists.first { $0.id == 4 })
        XCTAssertEqual(renamed.name, "Late night")
        XCTAssertGreaterThan(renamed.modifiedAt, night.modifiedAt)
        XCTAssertEqual(renamed.createdAt, night.createdAt)
        XCTAssertEqual(try synced.lastBody()?["name"] as? String, "Late night")
        XCTAssertEqual(try synced.lastBody()?["kind"] as? String, "movies")
        XCTAssertEqual(try synced.lastTouched(), ["playlist \(UID.n(4))"])

        let deleted = await model.delete(night)
        XCTAssertTrue(deleted)
        XCTAssertEqual(model.playlists.map(\.id), [6, 3, 5])
        let queued = try synced.queued()
        XCTAssertEqual(
            queued,
            [
                "replacePlaylist PUT /profiles/\(UID.n(1))/playlists/\(UID.n(4))",
                "deletePlaylist DELETE /profiles/\(UID.n(1))/playlists/\(UID.n(4))",
            ])
        XCTAssertTrue(transport.sent.isEmpty, "nothing goes until the queue flushes")
    }

    /// Nude (82), a song of one edition, already in Sunday drive at a0; Dune
    /// (20) of a standard and an extended edition; Arrival (21) of one; Severance (70).
    private func fillAddable() async throws {
        try await synced.replica.write { db in
            try db.library(2, "music")
            try db.music(80, "artist", "Radiohead")
            try db.music(81, "album", "In Rainbows", parent: 80)
            try db.music(82, "song", "Nude", parent: 81)
            try db.music(83, "song", "Reckoner", parent: 81)
            try db.edition(182, of: 82, ms: 255_000)
            try db.edition(183, of: 83, ms: 290_000)
            try db.entry(39, in: 3, item: 82, rank: "a0")
            try db.item(20, "movie", "Dune", rating: "PG-13")
            try db.edition(121, of: 20, ms: 10_800_000, tag: "Extended")
            try db.edition(120, of: 20, ms: 9_960_000)
            try db.item(21, "movie", "Arrival", rating: "PG")
            try db.edition(122, of: 21, ms: 6_960_000)
            try db.item(70, "show", "Severance", rating: "TV-MA")
            try db.collection(30, "Comet saga", source: "tmdb")
        }
    }

    func testAddsAreQueuedAndShowAtOnceUnderTheirClientIds() async throws {
        try await fillAddable()
        transport.failure = URLError(.notConnectedToInternet)

        let added = await model.add(83, to: 3, at: 0)
        XCTAssertTrue(added)
        XCTAssertNil(model.error)
        let musicRead = await model.entries(of: 3)
        let music = try XCTUnwrap(musicRead)
        XCTAssertEqual(music.map(\.itemId), [83, 82], "placed at the top")
        let song = music[0]
        XCTAssertEqual(song.rank, "Zz")
        XCTAssertEqual(song.editionId, 183, "a title's only edition, as the server takes it")
        XCTAssertEqual(song.addedAt, song.createdAt)
        XCTAssertEqual(song.createdAt, song.modifiedAt)
        XCTAssertEqual(song.createdBy, 1)
        XCTAssertEqual(song.modifiedBy, 1)
        var body = try XCTUnwrap(try synced.lastBody())
        XCTAssertEqual(body["id"] as? String, song.id.description)
        XCTAssertEqual(body["itemId"] as? String, UID.n(83).description)
        XCTAssertEqual(body["rank"] as? String, "Zz", "the rank written here, so the server writes the same")
        XCTAssertEqual(body["editionId"] as? String, UID.n(183).description)
        XCTAssertNil(body["position"])
        XCTAssertEqual(try synced.lastTouched(), ["playlist_entry \(song.id)"])

        let collection = await model.add(collection: 30, to: 4)
        XCTAssertTrue(collection)
        let show = await model.add(70, to: 6)
        XCTAssertTrue(show, "Ours is shared with Avery's household to write")
        let tvRead = await model.entries(of: 6)
        XCTAssertNil(try XCTUnwrap(tvRead).first?.editionId, "a container plays no one edition")
        let batch = await model.add([21, 20], to: 4)
        XCTAssertTrue(batch)
        XCTAssertNil(model.error)

        let moviesRead = await model.entries(of: 4)
        let movies = try XCTUnwrap(moviesRead)
        XCTAssertEqual(movies.map(\.kind), [.collection, .movie, .movie])
        XCTAssertEqual(movies.map(\.collectionId), [30, nil, nil])
        XCTAssertEqual(movies.map(\.itemId), [nil, 21, 20])
        XCTAssertEqual(movies.map(\.rank), ["a0", "a1", "a2"])
        XCTAssertEqual(movies.map(\.editionId), [nil, 122, 120], "a batch takes a title's default edition")
        body = try XCTUnwrap(try synced.lastBody())
        let sent = try XCTUnwrap(body["entries"] as? [[String: Any]])
        XCTAssertEqual(sent.map { $0["id"] as? String }, movies.dropFirst().map(\.id.description))
        XCTAssertEqual(sent.map { $0["itemId"] as? String }, [UID.n(21).description, UID.n(20).description])
        XCTAssertEqual(sent.map { $0["editionId"] as? String }, [UID.n(122).description, UID.n(120).description])
        XCTAssertEqual(sent.compactMap { $0["rank"] }.count, 0, "the server ranks a batch itself")
        XCTAssertEqual(
            try synced.lastTouched(), movies.dropFirst().map { "playlist_entry \($0.id)" })

        let path = "/profiles/\(UID.n(1))/playlists"
        XCTAssertEqual(
            try synced.queued(),
            [
                "addPlaylistEntry POST \(path)/\(UID.n(3))/entries",
                "addPlaylistEntry POST \(path)/\(UID.n(4))/entries",
                "addPlaylistEntry POST \(path)/\(UID.n(6))/entries",
                "addPlaylistEntries POST \(path)/\(UID.n(4))/entries/batch",
            ])
        XCTAssertTrue(transport.sent.isEmpty, "nothing goes until the queue flushes")
    }

    func testABatchBeyondWhatAnActionMayTouchGoesToTheServerAtOnce() async throws {
        let ids = (0...ActionQueue.touchedLimit).map { UID.n(1000 + $0) }
        try await synced.replica.write { db in
            for id in ids { try db.item(id, "movie", "Movie") }
        }
        transport.routes["POST /profiles/\(UID.n(1))/playlists/\(UID.n(4))/entries/batch"] = (.noContent, "")
        let added = await model.add(ids, to: 4)
        XCTAssertTrue(added)
        XCTAssertNil(model.error)
        let sent = transport.json(.post, "/profiles/\(UID.n(1))/playlists/\(UID.n(4))/entries/batch")?["entries"]
        let entries = try XCTUnwrap(sent as? [[String: Any]])
        XCTAssertEqual(entries.compactMap { $0["itemId"] as? String }, ids.map(\.description))
        XCTAssertEqual(Set(entries.compactMap { $0["id"] as? String }).count, ids.count)
        XCTAssertEqual(try synced.queued(), [])
        XCTAssertTrue(synced.caughtUp, "its rows come by sync")
    }

    func testARefusedAddSaysWhyAndQueuesNothing() async throws {
        try await fillAddable()
        let song = await model.add(82, to: 4)
        XCTAssertFalse(song)
        XCTAssertEqual(model.error, "The item does not belong in this kind of playlist.")
        let collection = await model.add(collection: 30, to: 3)
        XCTAssertFalse(collection)
        XCTAssertEqual(model.error, "The item does not belong in this kind of playlist.")
        let readOnly = await model.add(20, to: 5)
        XCTAssertFalse(readOnly)
        XCTAssertEqual(model.error, "Your access to this playlist does not allow that.")
        let batch = await model.add([21, 82], to: 4)
        XCTAssertFalse(batch, "one refused title refuses the batch, as the server does")
        XCTAssertEqual(try synced.queued(), [])
        XCTAssertTrue(transport.sent.isEmpty)
    }

    func testAnAddCarriesTheChosenEdition() async throws {
        try await fillAddable()
        let added = await model.add(20, to: 4, edition: 121)
        XCTAssertTrue(added)
        XCTAssertEqual(try synced.lastBody()?["editionId"] as? String, UID.n(121).description)
        let entriesRead = await model.entries(of: 4)
        XCTAssertEqual(try XCTUnwrap(entriesRead).map(\.editionName), ["Extended"])
    }

    func testATitleOfSeveralEditionsAddedWithoutOneAsksWhichThenAddsIt() async throws {
        try await synced.replica.write { db in
            try db.item(20, "movie", "Ferrous Tide")
            try db.edition(5, of: 20, ms: 6_000_000, tag: "Standard")
            try db.edition(6, of: 20, ms: 7_000_000, tag: "Extended")
            try db.item(22, "movie", "Before")
            try db.entry(40, in: 4, item: 22, rank: "a0")
            try db.entry(41, in: 4, item: 22, rank: "a1")
        }
        transport.failure = URLError(.notConnectedToInternet)
        let first = await model.add(20, to: 4, at: 1)
        XCTAssertFalse(first)
        XCTAssertNil(model.error, "a question, not a failure")
        let question = try XCTUnwrap(model.editionQuestion)
        XCTAssertEqual(question.editions.map(\.name), ["Standard", "Extended"])
        XCTAssertEqual(try synced.queued(), [], "nothing is added until one is picked")

        let added = await model.answer(question, with: question.editions[1])
        XCTAssertTrue(added)
        XCTAssertNil(model.editionQuestion)
        let sent = try XCTUnwrap(try synced.lastBody())
        XCTAssertEqual(sent["itemId"] as? String, UID.n(20).description)
        XCTAssertEqual(sent["editionId"] as? String, UID.n(6).description)
        XCTAssertEqual(sent["rank"] as? String, "a0V", "at the position asked")
        let entriesRead = await model.entries(of: 4)
        XCTAssertEqual(try XCTUnwrap(entriesRead).map(\.itemId), [22, 20, 22])
        XCTAssertTrue(transport.sent.isEmpty)
    }

    func testAnItemTheReplicaLacksIsNotFoundNotAQuestion() async {
        let added = await model.add(20, to: 4)
        XCTAssertFalse(added)
        XCTAssertNil(model.editionQuestion)
        XCTAssertEqual(model.error, "not found")
        let queued = try? synced.queued()
        XCTAssertEqual(queued, [])
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
