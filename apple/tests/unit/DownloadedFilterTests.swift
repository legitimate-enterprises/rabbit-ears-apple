import Foundation
import GRDB
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// What the profile can play from this device, which the Downloaded filter keeps.
@MainActor
final class DownloadedFilterTests: XCTestCase {
    var harness: DownloadHarness!
    var store: DownloadStore { harness.store }

    override func setUp() async throws {
        harness = DownloadHarness()
        try await harness.replica.write { db in
            try db.item(10, "show", "Severance")
            try db.item(11, "season", "Season 1", parent: 10, season: 1)
            try db.item(101, "episode", "Good News", parent: 11, season: 1, episode: 1)
            try db.item(12, "season", "Season 2", parent: 10, season: 2)
            try db.item(20, "movie", "Dune")
            try db.item(21, "movie", "Arrival")
            try db.artist(40, "Radiohead")
            try db.artist(42, "Guest")
            try db.album(50, "In Rainbows", artist: 40)
            try db.album(51, "OK Computer", artist: 40)
            try db.song(5, "Weird Fishes", album: 50, track: 4, performer: 42)
            try db.channel(60, "Workbench Weekly")
            try db.channel(61, "Clockwork Corner")
            try db.video(70, "Dovetails", channel: 60)
        }
        harness.resolves["item/\(UID.n(10))"] = [Fixtures.downloadTitle(101, "episode")]
        harness.resolves["item/\(UID.n(5))"] = [Fixtures.downloadTitle(5, "song", library: 3)]
        harness.resolves["item/\(UID.n(70))"] = [Fixtures.downloadTitle(70, "video", library: 4)]
        harness.resolves["item/\(UID.n(20))"] = [Fixtures.downloadTitle(20, "movie")]
    }

    func testEachTitleOnTheDeviceIsPlayableAndSoIsEachContainerAboveIt() async throws {
        for target in [DownloadTarget.show(10), .title(5), .title(70), .title(20)] {
            try await harness.download(target)
        }
        XCTAssertEqual(
            store.playable(profile: 1), [101, 11, 10, 5, 50, 40, 42, 70, 60, 20],
            "an episode with its season and show, a song with its album, album artist and performer, "
                + "a video with its channel, and a movie")
        for id: UID in [12, 21, 51, 61] { XCTAssertFalse(store.isPlayable(id, profile: 1), "\(id) has nothing here") }
        XCTAssertEqual(store.playable(profile: 2), [], "a profile plays only what its own requests cover")

        store.ledger.titles[20]?.state = .pending
        XCTAssertFalse(store.isPlayable(20, profile: 1), "a title still downloading is not playable")
    }

    func testTheFilterIsOffByDefault() {
        XCTAssertFalse(store.downloadedOnly)
    }
}
