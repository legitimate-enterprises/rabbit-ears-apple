import Foundation
import GRDB
import HTTPTypes
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// A download keeps the art its title, what holds the title and its
/// playlist show with, as the replica names them; only the art is fetched.
@MainActor
final class DownloadArtTests: XCTestCase {
    var harness: DownloadHarness!
    var store: DownloadStore { harness.store }

    override func setUp() async throws {
        harness = DownloadHarness()
        try await harness.replica.write { db in
            try db.account(2, "Robin")
            try db.item(10, "show", "Severance")
            try db.item(11, "season", "Season 1", parent: 10, season: 1)
            try db.item(101, "episode", "Good News", parent: 11, season: 1, episode: 1)
            try db.item(20, "movie", "Dune")
            try db.artist(40, "Radiohead")
            try db.album(50, "In Rainbows", artist: 40)
            try db.song(5, "Reckoner", album: 50, track: 7)
            try db.channel(60, "Workbench Weekly")
            try db.video(70, "Dovetails", channel: 60)
            try db.playlist(3, "Mine")
            try db.entry(1, in: 3, item: 20, rank: "a0")
            try db.playlist(4, "Robin's", owner: 2)
            try db.entry(2, in: 4, item: 101, rank: "a0")
        }
        try await harness.replica.write { db in
            for id in [10, 11, 101, 20, 50, 60, 70] {
                try db.art(.n(id), poster: ArtworkTests.address("p\(id)"), backdrop: ArtworkTests.address("b\(id)"))
            }
            // An artist shows its newest album's cover.
            try db.art(40, poster: ArtworkTests.address("p50"))
        }
        harness.transport.headers[.eTag] = "\"a\""
        harness.transport.headers[.cacheControl] = "private, max-age=31536000, immutable"
        for id in [10, 11, 101, 20, 50, 60, 70, 21] {
            for kind in ["p", "b"] { harness.transport.routes["GET /artwork/w500/\(kind)\(id).jpg"] = (.ok, "jpeg") }
        }
        harness.resolves["item/\(UID.n(10))"] = [Fixtures.downloadTitle(101, "episode")]
        harness.resolves["item/\(UID.n(5))"] = [Fixtures.downloadTitle(5, "song", library: 3)]
        harness.resolves["item/\(UID.n(70))"] = [Fixtures.downloadTitle(70, "video", library: 4)]
        harness.resolves["item/\(UID.n(20))"] = [Fixtures.downloadTitle(20, "movie")]
        harness.resolves["playlist/\(UID.n(3))"] = [Fixtures.downloadTitle(20, "movie")]
        harness.resolves["playlist/\(UID.n(4))"] = [Fixtures.downloadTitle(20, "movie")]
    }

    func testEachTitleKeepsItsOwnArtAndWhatHoldsIts() async throws {
        for target in [DownloadTarget.show(10), .title(5), .title(70)] { try await harness.download(target) }
        XCTAssertEqual(
            store.ledger.titles[101]?.art, ["p101", "b101", "p11", "b11", "p10", "b10"].map { "w500-\($0).jpg" })
        XCTAssertEqual(store.ledger.titles[5]?.art, ["w500-p50.jpg"], "the album's cover, once")
        XCTAssertEqual(store.ledger.titles[70]?.art, ["w500-p70.jpg", "w500-p60.jpg"])
        XCTAssertEqual(described(), [], "the replica names them")
    }

    func testAPlaylistKeepsItsArtTitlesOnlyWhereItReachesTheProfile() async throws {
        try await harness.download(.playlist(4))
        try await harness.download(.playlist(3))
        // A request is described after it is kept, in a task of its own.
        for _ in 0..<200 where store.ledger.requests.last?.art == nil { try await Task.sleep(for: .milliseconds(10)) }
        let art = store.ledger.requests.map { [$0.target.id: $0.art ?? []] }
        XCTAssertEqual(art, [[4: []], [3: ["w500-p20.jpg"]]])
        XCTAssertEqual(described(), [])
    }

    func testADownloadedTitlesArtFollowsItsAddressAtTheNextSync() async throws {
        try await harness.download(.title(20))
        try await harness.replica.write {
            try $0.art(20, poster: ArtworkTests.address("p21"), backdrop: ArtworkTests.address("b20"))
        }
        await store.sync(profile: 1)
        XCTAssertEqual(store.ledger.titles[20]?.art, ["w500-p21.jpg", "w500-b20.jpg"])
        let art = harness.directory.appending(path: "art").path(percentEncoded: false)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: art)), ["w500-p21.jpg", "w500-b20.jpg"])
        XCTAssertEqual(harness.transport.paths(.get).filter { $0.hasPrefix("/artwork/") }.count, 3)
    }

    /// The server reads a describe would have made, not counting art.
    private func described() -> [String] {
        harness.transport.sent.map(\.path).filter {
            $0.contains("/music/songs/") || $0.contains("/youtube/videos/") || $0.contains("/playlists/")
                || $0.hasPrefix("/items/")
        }
    }
}
