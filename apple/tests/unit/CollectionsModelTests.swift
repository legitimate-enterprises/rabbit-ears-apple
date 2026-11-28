import Foundation
import HTTPTypes
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

extension Fixtures {
    static func collection(_ id: UID, _ name: String, source: String = "custom", count: Int = 0) -> String {
        let owner =
            source == "custom" ? #""householdId":"\#(UID.n(1))","# : #""tmdbId":600,"overview":"Three of them.","#
        return #"{"id":"\#(id)","source":"\#(source)","name":"\#(name)","movieCount":\#(count),\#(owner)"#
            + #""customOrder":false,"createdAt":"2026-01-01T00:00:00Z","modifiedAt":"2026-01-01T00:00:00Z"}"#
    }

    /// The same collection with its movies in a hand-made order.
    static func handOrdered(_ collection: String) -> String {
        collection.replacingOccurrences(of: #""customOrder":false"#, with: #""customOrder":true"#)
    }
}

@MainActor
final class CollectionsModelTests: XCTestCase {
    var synced: SyncedReplica!
    var model: CollectionsModel!

    /// Household 7's Movie night (7, empty) and Rainy days (8), TMDB's
    /// Comet saga (6, three movies) and Solo (5, one), and Elsewhere (9) of
    /// another household. Kit (2) is a kid under PG.
    override func setUp() async throws {
        synced = try SyncedReplica { db in
            try db.account(1, "Avery")
            try db.account(2, "Kit", kind: "kid", movies: "PG")
            try db.item(10, "movie", "Comet", rating: "PG", year: 2016)
            try db.item(11, "movie", "Comet II", rating: "R", year: 2019)
            try db.item(12, "movie", "Comet III", rating: "PG", year: 2012)
            try db.item(13, "movie", "Puddles", rating: "G")
            try db.collection(6, "Comet saga", source: "tmdb")
            try db.collection(5, "Solo", source: "tmdb")
            try db.collection(7, "Movie night")
            try db.collection(8, "Rainy days")
            try db.collection(9, "Elsewhere", household: 8)
            for movie: UID in [10, 11, 12] { try db.collect(movie, in: 6) }
            try db.collect(13, in: 5)
            try db.collect(13, in: 8)
            try db.collect(10, in: 9)
        }
        addTeardownBlock { [synced] in await synced?.remove() }
        model = synced.collections()
        await model.load()
    }

    func testASmartCollectionTakesNoHandEditsAndNoPickerOffersIt() async throws {
        try await synced.replica.write {
            try $0.execute(
                sql: "INSERT INTO smart_list(id, collection_id, created_at) VALUES (?, ?, 0)",
                arguments: [UID.n(70), UID.n(8)])
        }
        let refusal = "A smart collection's movies follow its rules."
        let added = await model.add(movie: 10, to: 8)
        XCTAssertFalse(added)
        XCTAssertEqual(model.error, refusal)
        await model.remove(movie: 13, from: 8)
        XCTAssertEqual(model.error, refusal)
        let moved = await model.move(13, in: 8, to: 0)
        XCTAssertFalse(moved)
        XCTAssertEqual(model.error, refusal)
        XCTAssertEqual(try synced.queued(), [])
        XCTAssertEqual(model.custom.map(\.id), [7, 8])
        model.collections = model.collections.map { collection in
            var collection = collection
            collection.smart = collection.id == 8
            return collection
        }
        XCTAssertEqual(model.custom.map(\.id), [7], "Add to collection leaves it out")
    }

    /// The spec's maxLength counts code points, so a collection's, a
    /// playlist's and a station's name is cut to 100 of them between characters.
    func testANameIsCutToTheServersLengthInWholeCharacters() async throws {
        let family = "👨‍👩‍👧‍👦"
        let name = String(repeating: family, count: 100)
        let cut = String(repeating: family, count: 14)
        XCTAssertEqual(family.unicodeScalars.count, 7)
        XCTAssertEqual(name.prefix(scalars: 100), cut)
        XCTAssertEqual("ab".prefix(scalars: 100), "ab")

        let collection = await model.create(name: name)
        XCTAssertEqual(collection?.name, cut)
        let playlist = await synced.playlists().create(name: name, kind: .movies)
        XCTAssertEqual(playlist?.name, cut)
        var station = StationForm(kind: .movies)
        station.name = name
        XCTAssertEqual(station.input?.name, cut)
    }

    func testLoadsWhatTheHouseholdAndProfileMaySeeByName() async {
        XCTAssertEqual(model.collections.map(\.id), [6, 7, 8])
        XCTAssertEqual(model.custom.map(\.name), ["Movie night", "Rainy days"])
        XCTAssertEqual(model.collections.map(\.summary), ["3 movies", "0 movies", "1 movie"])
        XCTAssertEqual(model.collections.map(\.tmdbId), [600, nil, nil])
        XCTAssertEqual(model.collections.map(\.householdId), [nil, 7, 7])
        XCTAssertEqual(model.collections.first?.overview, "Three of them.")
        XCTAssertNil(model.error)

        let kid = synced.collections(2)
        await kid.load()
        XCTAssertEqual(kid.collections.map(\.id), [6, 8], "a kid sees none without a movie it may see")
        XCTAssertEqual(kid.collections.map(\.movieCount), [2, 1])
    }

    func testMoviesComeInReleaseOrderAndOnlyThoseTheProfileMaySee() async throws {
        let read = await model.movies(of: 6)
        XCTAssertEqual(try XCTUnwrap(read).map(\.id), [12, 10, 11])
        let kid = synced.collections(2)
        let seen = await kid.movies(of: 6)
        XCTAssertEqual(seen?.map(\.id), [12, 10])
        let unreadable = await model.movies(of: 9)
        XCTAssertNil(unreadable, "another household's")
        XCTAssertNotNil(model.error)
    }

    func testACollectionReachedByALinkIsReadWithItsMovies() async {
        let fresh = synced.collections()
        let read = await fresh.movies(of: 8)
        XCTAssertEqual(read?.map(\.id), [13])
        XCTAssertEqual(fresh.collections.map(\.name), ["Rainy days"])
    }

    /// Offline, a new collection is the household's at once under the id
    /// this device gave it, and the queued call names the same id.
    func testACreateShowsAtOnceOfflineUnderItsClientId() async throws {
        synced.transport.failure = URLError(.notConnectedToInternet)
        let blank = await model.create(name: "  ")
        XCTAssertNil(blank)
        let made = try await unwrapped(await model.create(name: " Snow days "))
        XCTAssertEqual(made.name, "Snow days")
        XCTAssertEqual(made.source, .custom)
        XCTAssertEqual(made.householdId, 7, "the device's household")
        XCTAssertNil(made.tmdbId)
        XCTAssertNil(made.overview)
        XCTAssertEqual(made.createdBy, 1)
        XCTAssertEqual(made.modifiedBy, 1)
        XCTAssertEqual(made.createdAt, made.modifiedAt)
        XCTAssertEqual(model.custom.map(\.name), ["Movie night", "Rainy days", "Snow days"])
        let stored: [UID] = try await synced.read(
            "SELECT id FROM collection WHERE typeof(id) = 'blob' AND length(id) = 16 AND name = 'Snow days'")
        XCTAssertEqual(stored, [made.id])
        XCTAssertEqual(try synced.queued(), ["createCollection POST /collections"])
        let body = try XCTUnwrap(try synced.lastBody())
        XCTAssertEqual(body["id"] as? String, "\(made.id)")
        XCTAssertEqual(body["name"] as? String, "Snow days")
        XCTAssertEqual(try synced.lastTouched(), ["collection \(made.id)"])
        XCTAssertTrue(synced.transport.sent.isEmpty, "nothing is sent until the queue flushes")
        XCTAssertNil(model.error)
    }

    func testRenameAndDeleteAreQueuedAndDeleteTakesTheEntriesHoldingIt() async throws {
        try await synced.replica.write { db in
            try db.playlist(3, "Mix")
            try db.entry(30, in: 3, collection: 8, rank: "a0")
            try db.entry(31, in: 3, item: 13, rank: "a1")
        }
        let rainy = model.collections[2]
        await model.rename(rainy, to: " Snowed in ")
        XCTAssertEqual(model.collections.map(\.name), ["Comet saga", "Movie night", "Snowed in"])
        XCTAssertEqual(try synced.lastBody()?["name"] as? String, "Snowed in")

        await model.delete(rainy)
        XCTAssertEqual(model.collections.map(\.id), [6, 7])
        XCTAssertEqual(try synced.lastTouched(), ["collection \(UID.n(8))", "playlist_entry \(UID.n(30))"])
        let entries: [UID] = try await synced.read("SELECT id FROM playlist_entry")
        XCTAssertEqual(entries, [31])
        let queued = try synced.queued()
        XCTAssertEqual(
            queued,
            [
                "replaceCollection PUT /collections/\(UID.n(8))", "deleteCollection DELETE /collections/\(UID.n(8))",
            ])
        XCTAssertNil(model.error)
    }

    func testAddingAndRemovingAMovieIsQueuedAndRecounted() async throws {
        let added = await model.add(movie: 10, to: 7)
        XCTAssertTrue(added)
        XCTAssertEqual(model.collections.first { $0.id == 7 }?.movieCount, 1)
        XCTAssertEqual(try synced.lastTouched(), ["collection_movie \(UID.n(7)) \(UID.n(10))"])
        await model.remove(movie: 10, from: 7)
        XCTAssertEqual(model.collections.first { $0.id == 7 }?.movieCount, 0)
        let queued = try synced.queued()
        XCTAssertEqual(
            queued,
            [
                "addCollectionMovie PUT /collections/\(UID.n(7))/movies/\(UID.n(10))",
                "removeCollectionMovie DELETE /collections/\(UID.n(7))/movies/\(UID.n(10))",
            ])
        XCTAssertNil(model.error)
    }

    func testATMDBCollectionIsRefusedAtOnceAndLeftAsItWas() async throws {
        let before = model.collections
        let added = await model.add(movie: 13, to: 6)
        XCTAssertFalse(added)
        XCTAssertEqual(model.error, "A TMDB collection cannot be changed.")
        let moved = await model.move(10, in: 6, to: 1)
        XCTAssertFalse(moved)
        let reset = await model.resetOrder(of: 6)
        XCTAssertFalse(reset)
        XCTAssertEqual(model.collections, before)
        let queued = try synced.queued()
        XCTAssertEqual(queued, [])
    }

    func testAMoviesCollectionsAreThoseHoldingItThatTheProfileMaySee() async {
        let named = await model.collections(of: 13)
        XCTAssertEqual(named.map(\.name), ["Rainy days"], "Solo holds too few to show")
        let comet = await model.collections(of: 11)
        XCTAssertEqual(comet.map(\.name), ["Comet saga"])
        let kid = await synced.collections(2).collections(of: 11)
        XCTAssertEqual(kid, [], "a movie the profile may not open names none")
    }

    func testMovingNumbersEveryMovieAndTheFlagFollowsThenAResetClearsIt() async throws {
        try await synced.replica.write { db in
            for movie: UID in [10, 11, 12] { try db.collect(movie, in: 7) }
        }
        await model.load()
        XCTAssertEqual(model.collections.first { $0.id == 7 }?.isHandOrdered, false)
        let moved = await model.reorder(12, in: 7, to: 2)
        XCTAssertEqual(try XCTUnwrap(moved).map(\.id), [10, 11, 12])
        XCTAssertEqual(model.collections.first { $0.id == 7 }?.isHandOrdered, true)
        XCTAssertEqual(try synced.lastBody()?["position"] as? Int, 2)
        XCTAssertEqual(
            try synced.lastTouched(), [12, 10, 11].map { "collection_movie \(UID.n(7)) \(UID.n($0))" })
        let positions: [Int64] = try await synced.read(
            "SELECT position FROM collection_movie WHERE collection_id = \(sqlID(7)) ORDER BY item_id")
        XCTAssertEqual(positions, [0, 1, 2])

        let reset = await model.restoreReleaseOrder(of: 7)
        XCTAssertEqual(reset?.map(\.id), [12, 10, 11])
        XCTAssertEqual(model.collections.first { $0.id == 7 }?.isHandOrdered, false)
        let queued = try synced.queued()
        XCTAssertEqual(
            queued,
            [
                "replaceCollectionMoviePosition PUT /collections/\(UID.n(7))/movies/\(UID.n(12))/position",
                "resetCollectionOrder DELETE /collections/\(UID.n(7))/order",
            ])
        XCTAssertNil(model.error)
    }

    func testARefusedReorderStillReadsTheMoviesAndKeepsTheError() async throws {
        let read = await model.reorder(10, in: 6, to: 0)
        XCTAssertEqual(try XCTUnwrap(read).map(\.id), [12, 10, 11])
        XCTAssertEqual(model.error, "A TMDB collection cannot be changed.")
    }

    func testARowReadsItsYearAndRuntime() {
        let movie: Item = Fixtures.decode(Fixtures.item(10, "movie", "Comet", runtime: 124, year: 2016))
        XCTAssertEqual(CollectionsModel.detail(of: movie), "2016 · 2h 4m")
        XCTAssertEqual(CollectionsModel.detail(of: Fixtures.decode(Fixtures.item(11, "movie", "Comet II"))), "")
    }

    func testACopyStoredBeforeTheFlagExistedReadsAsReleaseOrder() throws {
        let stored = Fixtures.collection(7, "Movie night").replacingOccurrences(of: #""customOrder":false,"#, with: "")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let collection = try decoder.decode(MovieCollection.self, from: Data(stored.utf8))
        XCTAssertNil(collection.customOrder)
        XCTAssertFalse(collection.isHandOrdered)
    }

    func testADropOffsetBelowTheOldPlaceCountsTheMovieItself() {
        XCTAssertEqual(CollectionsModel.position(moving: 1, toOffset: 4), 3)
        XCTAssertEqual(CollectionsModel.position(moving: 3, toOffset: 1), 1)
        XCTAssertEqual(CollectionsModel.position(moving: 2, toOffset: 3), 2)
        XCTAssertEqual(CollectionsModel.position(moving: 2, toOffset: 2), 2)
    }

    func testAHandOrderedCollectionKeepsItsOrderWhateverTheYears() async throws {
        try await synced.replica.write { db in
            try db.collect(10, in: 7, at: 1)
            try db.collect(11, in: 7, at: 0)
            try db.collect(12, in: 7, at: 2)
        }
        await model.load()
        XCTAssertEqual(model.collections.first { $0.id == 7 }?.isHandOrdered, true)
        let read = await model.movies(of: 7)
        XCTAssertEqual(try XCTUnwrap(read).map(\.id), [11, 10, 12])
    }
}
