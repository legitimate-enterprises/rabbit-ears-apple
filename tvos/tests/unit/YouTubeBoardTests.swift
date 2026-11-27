import Foundation
import GRDB
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

@MainActor
final class YouTubeBoardTests: XCTestCase {
    var fixture: ReplicaFixture!
    var replica: Replica!
    var board: YouTubeBoard!

    /// Workbench Weekly (60) with 101 videos, one more than a page, the
    /// longer the higher the id; Clockwork Corner (61) with one, watched.
    override func setUp() async throws {
        fixture = ReplicaFixture()
        replica = try fixture.v1 { db in
            try db.account(1, "Avery")
            try db.channel(60, "Workbench Weekly")
            try db.channel(61, "Clockwork Corner")
            for id in Int64(100)...200 {
                try db.video(id, "Video \(id)", channel: 60, durationMs: id * 1000, added: "2026-01-01T00:00:00Z")
            }
            try db.video(300, "Gears", channel: 61, published: "2026-11-12T00:00:00Z")
            try db.watch(300, for: 1, watched: true)
        }
        let client = ServerEndpoint(userInput: "192.168.1.9")!.client(token: "t", transport: RoutingTransport())
        board = YouTubeBoard(
            youTube: YouTubeModel(
                client: client, replica: replica, queue: ActionQueue(replica: replica, client: client),
                profileId: 1))
    }

    override func tearDown() async throws { fixture.remove() }

    func testVideosTakeTheSortAndChannelAndPageOnDemand() async {
        await board.load(.videos, sort: .length, channel: 60)
        XCTAssertEqual(board.videos?.items.count, 100)
        XCTAssertEqual(board.videos?.items.first?.id, 200, "longest first")
        XCTAssertEqual(board.videos?.done, false)
        await board.videos?.loadMore()
        XCTAssertEqual(board.videos?.items.last?.id, 100)
        XCTAssertEqual(board.videos?.done, true)
    }

    func testUnwatchedIsTheVideosListFilteredToUnwatched() async {
        await board.load(.unwatched, sort: .newest, channel: 61)
        XCTAssertEqual(board.videos?.items.map(\.id), [])
        await board.load(.videos, sort: .newest, channel: 61)
        XCTAssertEqual(board.videos?.items.map(\.id), [300])
    }

    func testChannelsGiveTheCountForEveryTab() async {
        await board.loadChannels()
        XCTAssertEqual(board.caption, "2 channels")
        XCTAssertEqual(board.channels.map(\.id), [61, 60])
    }

    func testRefreshRereadsTheLoadedPagesInPlace() async throws {
        await board.load(.videos, sort: .length, channel: 60)
        await board.videos?.loadMore()
        XCTAssertEqual(board.videos?.items.count, 101)
        let shown = board.videos
        try await replica.write { db in
            try db.watch(200, for: 1, watched: true)
            try db.watch(100, for: 1, watched: true)
        }
        await board.refresh(.videos)
        XCTAssertTrue(board.videos === shown)
        XCTAssertEqual(board.videos?.items.count, 101)
        XCTAssertEqual(board.videos?.items.first?.watched, true)
        XCTAssertEqual(board.videos?.items.last?.watched, true)
    }

    func testChangingTheSortStartsOverFromTheFirstPage() async {
        await board.load(.videos, sort: .length, channel: nil)
        let shown = board.videos
        await board.load(.videos, sort: .title, channel: nil)
        XCTAssertFalse(board.videos === shown)
        XCTAssertEqual(board.videos?.items.first?.title, "Gears")
    }
}
