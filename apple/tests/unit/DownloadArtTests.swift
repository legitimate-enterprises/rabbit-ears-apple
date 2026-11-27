import Foundation
import GRDB
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
        for id in [10, 11, 101, 20, 40, 50, 60, 70] {
            for kind in ["poster", "backdrop"] {
                harness.transport.routes["GET /items/\(id)/artwork/\(kind)"] = (.ok, "jpeg")
            }
        }
        harness.resolves["item/10"] = [Fixtures.downloadTitle(101, "episode")]
        harness.resolves["item/5"] = [Fixtures.downloadTitle(5, "song", library: 3)]
        harness.resolves["item/70"] = [Fixtures.downloadTitle(70, "video", library: 4)]
        harness.resolves["playlist/3"] = [Fixtures.downloadTitle(20, "movie")]
        harness.resolves["playlist/4"] = [Fixtures.downloadTitle(20, "movie")]
    }

    func testEachTitleKeepsItsOwnArtAndWhatHoldsIts() async throws {
        for target in [DownloadTarget.show(10), .title(5), .title(70)] { try await harness.download(target) }
        XCTAssertEqual(
            store.ledger.titles[101]?.art,
            [
                "item-101-poster", "item-101-backdrop", "item-11-poster", "item-11-backdrop", "item-10-poster",
                "item-10-backdrop",
            ])
        XCTAssertEqual(Set(store.ledger.titles[5]?.art ?? []), ["item-50-poster", "item-40-poster"])
        XCTAssertEqual(store.ledger.titles[70]?.art, ["item-70-poster", "item-60-poster"])
        XCTAssertEqual(described(), [], "the replica names them")
    }

    func testAPlaylistKeepsItsArtTitlesOnlyWhereItReachesTheProfile() async throws {
        try await harness.download(.playlist(4))
        try await harness.download(.playlist(3))
        // A request is described after it is kept, in a task of its own.
        for _ in 0..<200 where store.ledger.requests.last?.art == nil { try await Task.sleep(for: .milliseconds(10)) }
        let art = store.ledger.requests.map { [$0.target.id: $0.art ?? []] }
        XCTAssertEqual(art, [[4: []], [3: ["item-20-poster"]]])
        XCTAssertEqual(described(), [])
    }

    /// The server reads a describe would have made, not counting art.
    private func described() -> [String] {
        harness.transport.sent.map(\.path).filter {
            $0.contains("/music/songs/") || $0.contains("/youtube/videos/") || $0.contains("/playlists/")
                || ($0.hasPrefix("/items/") && !$0.contains("/artwork/"))
        }
    }
}
