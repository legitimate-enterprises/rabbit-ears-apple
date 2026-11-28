import Foundation
import GRDB
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// A profile's favorites as the replica holds them: the stars it shows,
/// and its lists, most recently starred first, of what it browses.
@MainActor
final class FavoritesTests: XCTestCase {
    var fixture: ReplicaFixture!

    override func setUp() async throws { fixture = ReplicaFixture() }

    override func tearDown() async throws { fixture.remove() }

    /// Avery an adult (1), Bo an adult hiding kids' content (2) and Kit a
    /// kid to PG and TV-Y (3). Dune (20) is PG-13 and Toy Story (30) G;
    /// Alpha (10) is TV-Y with a season (11) and an episode (12). Radiohead
    /// (40) has In Rainbows (50) with Nude (1) and the explicit Weird Fishes
    /// (2); Shop (60) has a video (70). `n` minutes after the first star.
    private func library() throws -> Replica {
        try fixture.v1 { db in
            try db.account(1, "Avery")
            try db.account(2, "Bo", hidingKids: true)
            try db.account(3, "Kit", kind: "kid", movies: "PG", tv: "TV-Y")
            try db.item(20, "movie", "Dune", rating: "PG-13")
            try db.item(30, "movie", "Toy Story", rating: "G")
            try db.item(10, "show", "Alpha", rating: "TV-Y")
            try db.item(11, "season", "Season 1", parent: 10, season: 1)
            try db.item(12, "episode", "Pilot", parent: 11, season: 1, episode: 1)
            try db.library(3, "music")
            try db.artist(40, "Radiohead")
            try db.album(50, "In Rainbows", artist: 40)
            try db.song(1, "Nude", album: 50, track: 1)
            try db.song(2, "Weird Fishes", album: 50, track: 2, explicit: true)
            try db.library(4, "youtube")
            try db.channel(60, "Shop")
            try db.video(70, "Gears", channel: 60)
            let stars: [UID: [UID: Int64]] = [
                1: [20: 1, 30: 3, 10: 2, 11: 2, 12: 4, 40: 5, 50: 6, 1: 7, 2: 8, 70: 9],
                2: [20: 1, 30: 2], 3: [20: 1, 30: 2, 1: 3, 2: 4],
            ]
            for (profile, items) in stars {
                for (item, minute) in items {
                    try db.execute(
                        sql: "INSERT INTO favorite VALUES (?, ?, ?)",
                        arguments: [profile, item, 1_800_000_000_000 + minute * 60_000])
                }
            }
        }
    }

    private func shelves(_ replica: Replica, _ id: UID, only: FavoriteSection? = nil) async throws -> FavoriteShelves {
        try await replica.read { try Favorites.shelves($0, profile: id, only: only) }
    }

    func testTheStarsAreTheProfilesOwnOfWhatItMayOpen() async throws {
        let replica = try library()
        let favorites = Favorites()
        await favorites.load(profile: 1, replica: replica)
        XCTAssertEqual(favorites.ids, [20, 30, 10, 11, 12, 40, 50, 1, 2, 70])
        XCTAssertTrue(favorites.contains(30))
        await favorites.load(profile: 3, replica: replica)
        XCTAssertEqual(favorites.ids, [30, 1], "Dune is over Kit's ceiling and Weird Fishes explicit")
        XCTAssertEqual(favorites.sections, [.movies, .songs])
        await favorites.load(profile: 2, replica: replica)
        XCTAssertTrue(favorites.contains(30), "a hidden kids' title still shows its star")
    }

    func testTheSectionsAreInOrderEachMostRecentlyStarredFirst() async throws {
        let replica = try library()
        let favorites = Favorites()
        await favorites.load(profile: 1, replica: replica)
        XCTAssertEqual(favorites.sections, FavoriteSection.allCases)
        let all = try await shelves(replica, 1)
        XCTAssertEqual(all.sections, FavoriteSection.allCases)
        XCTAssertEqual(all.movies.map(\.id), [30, 20])
        XCTAssertEqual(all.shows.map(\.id), [10])
        XCTAssertEqual(all.seasons.map(\.id), [11])
        XCTAssertEqual(all.episodes.map(\.id), [12])
        XCTAssertEqual(all.artists.map(\.id), [40])
        XCTAssertEqual(all.albums.map(\.id), [50])
        XCTAssertEqual(all.songs.map(\.id), [2, 1])
        XCTAssertEqual(all.videos.map(\.id), [70])
    }

    func testAKidListsOnlyWhatItMayHearAndSee() async throws {
        let kid = try await shelves(library(), 3)
        XCTAssertEqual(kid.sections, [.movies, .songs])
        XCTAssertEqual(kid.movies.map(\.id), [30])
        XCTAssertEqual(kid.songs.map(\.id), [1])
    }

    func testAnAdultHidingKidsContentIsNotListedIt() async throws {
        let hiding = try await shelves(library(), 2)
        XCTAssertEqual(hiding.movies.map(\.id), [20])
    }

    func testOneKindReadsThatKindAlone() async throws {
        let replica = try library()
        let songs = try await shelves(replica, 1, only: .songs)
        XCTAssertEqual(songs.sections, [.songs])
        XCTAssertEqual(songs.songs.map(\.id), [2, 1])
        let shows = try await shelves(replica, 1, only: .shows)
        XCTAssertEqual(shows.sections, [.shows])
    }

    func testAChannelIsNoKindOfFavorite() {
        XCTAssertNil(FavoriteKind(rawValue: "channel"))
        XCTAssertEqual(FavoriteSection.allCases.map(\.kind.rawValue), FavoriteKind.allCases.map(\.rawValue))
    }
}
