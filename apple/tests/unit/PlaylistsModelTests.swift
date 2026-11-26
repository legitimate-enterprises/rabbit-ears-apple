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
    var transport: RoutingTransport!
    var model: PlaylistsModel!

    override func setUp() async throws {
        transport = RoutingTransport([
            "GET /profiles/1/playlists": (
                .ok,
                Fixtures.page([
                    Fixtures.playlist(3, "Sunday drive", count: 2),
                    Fixtures.playlist(4, "Kids movie night", kind: "movies"),
                ])
            ),
            "GET /profiles/1/playlists/3": (.ok, Fixtures.playlist(3, "Sunday drive", count: 3)),
        ])
        model = PlaylistsModel(
            client: ServerEndpoint(userInput: "192.168.1.9")!.client(token: "t", transport: transport), profileId: 1)
        await model.load()
    }

    func testLoadsEveryPlaylistAndFiltersByKind() {
        XCTAssertEqual(model.playlists.map(\.id), [3, 4])
        XCTAssertEqual(model.playlists(.music).map(\.name), ["Sunday drive"])
        XCTAssertEqual(model.playlists(.movies).map(\.name), ["Kids movie night"])
        XCTAssertEqual(model.playlists(.tv).map(\.name), [])
    }

    func testCreateRenameAndDelete() async throws {
        transport.routes["POST /profiles/1/playlists"] = (.created, Fixtures.playlist(5, "Road trip", kind: "tv"))
        transport.routes["PUT /profiles/1/playlists/5"] = (.ok, Fixtures.playlist(5, "Long road trip", kind: "tv"))
        transport.routes["DELETE /profiles/1/playlists/5"] = (.noContent, "")
        let blank = await model.create(name: "   ", kind: .tv)
        XCTAssertNil(blank)
        let made = await model.create(name: " Road trip ", kind: .tv)
        let created = try XCTUnwrap(made)
        let sentNew = transport.json(.post, "/profiles/1/playlists")
        XCTAssertEqual(sentNew?["name"] as? String, "Road trip")
        XCTAssertEqual(sentNew?["kind"] as? String, "tv")
        await model.rename(created, to: "Long road trip")
        let sent = transport.json(.put, "/profiles/1/playlists/5")
        XCTAssertEqual(sent?["name"] as? String, "Long road trip")
        XCTAssertEqual(sent?["kind"] as? String, "tv")
        XCTAssertEqual(model.playlists.last?.name, "Long road trip")
        await model.delete(created)
        XCTAssertEqual(model.playlists.map(\.id), [3, 4])
    }

    func testEntriesAddRemoveAndReorderRefreshTheCount() async throws {
        transport.routes["GET /profiles/1/playlists/3/entries"] = (
            .ok, Fixtures.page([Fixtures.entry(30, position: 0, song: 1), Fixtures.entry(31, position: 1, song: 2)])
        )
        transport.routes["POST /profiles/1/playlists/3/entries"] = (.created, Fixtures.entry(32, position: 0, song: 9))
        transport.routes["PUT /profiles/1/playlists/3/entries/31"] = (.ok, Fixtures.entry(31, position: 0, song: 2))
        transport.routes["DELETE /profiles/1/playlists/3/entries/30"] = (.noContent, "")
        let read = await model.entries(of: 3)
        let entries = try XCTUnwrap(read)
        XCTAssertEqual(entries.map(\.id), [30, 31])

        let added = await model.add(9, to: 3, at: 0)
        XCTAssertTrue(added)
        let sent = transport.json(.post, "/profiles/1/playlists/3/entries")
        XCTAssertEqual(sent?["itemId"] as? Int, 9)
        XCTAssertEqual(sent?["position"] as? Int, 0)
        XCTAssertEqual(model.playlists.first?.itemCount, 3)

        await model.move(entries[1], to: 0)
        let moved = transport.json(.put, "/profiles/1/playlists/3/entries/31")
        XCTAssertEqual(moved?["itemId"] as? Int, 2)
        XCTAssertEqual(moved?["position"] as? Int, 0)

        await model.remove(entries[0])
        XCTAssertEqual(transport.paths(.delete), ["/profiles/1/playlists/3/entries/30"])
        XCTAssertNil(model.error)
    }

    func testACollectionGoesInAsOneEntryAndMovesByItsId() async throws {
        let entry = Fixtures.entry(40, playlist: 4, position: 0, collection: 6)
        transport.routes["POST /profiles/1/playlists/4/entries"] = (.created, entry)
        transport.routes["PUT /profiles/1/playlists/4/entries/40"] = (.ok, entry)
        transport.routes["GET /profiles/1/playlists/4"] = (.ok, Fixtures.playlist(4, "Movie night", kind: "movies"))
        let added = await model.add(collection: 6, to: 4)
        XCTAssertTrue(added)
        let sent = try XCTUnwrap(transport.json(.post, "/profiles/1/playlists/4/entries"))
        XCTAssertEqual(sent["collectionId"] as? Int, 6)
        XCTAssertNil(sent["itemId"])

        await model.move(Fixtures.decode(entry), to: 1)
        let moved = try XCTUnwrap(transport.json(.put, "/profiles/1/playlists/4/entries/40"))
        XCTAssertEqual(moved["collectionId"] as? Int, 6)
        XCTAssertNil(moved["itemId"])
        XCTAssertEqual(moved["position"] as? Int, 1)
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

    func testThePlayOrderIsReadToTheLastPage() async throws {
        transport.respond = { sent in
            guard sent.path == "/profiles/1/playlists/3/play-order" else { return nil }
            return sent.query.contains("offset=200")
                ? (.ok, Fixtures.page([Fixtures.row(entry: 31, song: 7)]))
                : (
                    .ok,
                    #"{"items":[\#(Fixtures.row(entry: 30, song: 5)),\#(Fixtures.row(entry: 30, song: 6))],"#
                        + #""nextOffset":200}"#
                )
        }
        let read = await model.playOrder(of: 3)
        let rows = try XCTUnwrap(read)
        XCTAssertEqual(rows.songs.map(\.id), [5, 6, 7])
        XCTAssertEqual(rows.start(of: 31), 2)
        XCTAssertEqual(rows.start(of: 30), 0)
        XCTAssertNil(rows.start(of: 99), "an entry that stands for nothing now")
        XCTAssertEqual(transport.queries(.get, "/profiles/1/playlists/3/play-order").count, 2)
    }

    func testAnUnreadablePlayOrderIsNil() async {
        let read = await model.playOrder(of: 8)
        XCTAssertNil(read)
        XCTAssertNotNil(model.error)
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
        transport.routes["GET /profiles/1/playlists/4"] = (.ok, Fixtures.playlist(4, "Movie night", kind: "movies"))
        let added = await model.add(20, to: 4, edition: 6)
        XCTAssertTrue(added)
        XCTAssertEqual(transport.json(.post, "/profiles/1/playlists/4/entries")?["editionId"] as? Int, 6)
        let plain = await model.add(21, to: 4)
        XCTAssertTrue(plain)
        XCTAssertNil(transport.json(.post, "/profiles/1/playlists/4/entries")?["editionId"])
    }

    func testAnAddRefusedForWantOfAnEditionAsksWhichThenAddsIt() async throws {
        transport.routes["GET /profiles/1/playlists/4"] = (.ok, Fixtures.playlist(4, "Movie night", kind: "movies"))
        transport.routes["GET /items/20"] = (
            .ok,
            String(Fixtures.item(20, "movie", "Ferrous Tide").dropLast())
                + #","editions":[\#(Fixtures.edition(5, "Standard", isDefault: true)),"#
                + #"\#(Fixtures.edition(6, "Extended"))]}"#
        )
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
    func testDeletingAPlaylistAStationPlaysSaysSo() async {
        let transport = RoutingTransport([
            "GET /profiles/1/playlists": (.ok, Fixtures.page([Fixtures.playlist(3, "Sunday drive")])),
            "DELETE /profiles/1/playlists/3": (
                .conflict,
                Fixtures.error(
                    "conflict", "a station plays this playlist; delete the station or give it another playlist first")
            ),
        ])
        let model = PlaylistsModel(
            client: ServerEndpoint(userInput: "192.168.1.9")!.client(token: "t", transport: transport), profileId: 1)
        await model.load()
        let deleted = await model.delete(model.playlists[0])
        XCTAssertFalse(deleted)
        XCTAssertEqual(
            model.error, "A station plays this playlist. Delete the station or give it another playlist first.")
        XCTAssertEqual(model.playlists.map(\.id), [3])
    }
}
