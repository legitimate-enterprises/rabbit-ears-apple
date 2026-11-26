import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

@MainActor
final class YouTubeBoardTests: XCTestCase {
    var transport: RoutingTransport!
    var board: YouTubeBoard!

    override func setUp() async throws {
        transport = RoutingTransport()
        board = YouTubeBoard(
            youTube: YouTubeModel(
                client: ServerEndpoint(userInput: "192.168.1.9")!.client(token: "t", transport: transport),
                profileId: 1))
    }

    func testVideosAskForTheSortAndChannelAndPageOnDemand() async {
        transport.routes["GET /youtube/videos"] = (
            .ok, #"{"items":[\#(Fixtures.video(70, "The dishwasher video"))],"nextOffset":100}"#
        )
        await board.load(.videos, sort: .length, channel: 60)
        XCTAssertEqual(board.videos?.items.map(\.id), [70])
        XCTAssertEqual(board.videos?.done, false)
        XCTAssertEqual(transport.queries(.get, "/youtube/videos"), ["channelId=60&sort=length&limit=100"])
    }

    func testUnwatchedIsTheVideosListFilteredToUnwatched() async {
        transport.routes["GET /youtube/videos"] = (.ok, Fixtures.page([]))
        await board.load(.unwatched, sort: .newest, channel: nil)
        XCTAssertEqual(transport.queries(.get, "/youtube/videos"), ["unwatched=true&sort=newest&limit=100"])
    }

    func testChannelsGiveTheCountForEveryTab() async {
        transport.routes["GET /youtube/channels"] = (
            .ok, Fixtures.page([Fixtures.channel(60, "Workbench Weekly"), Fixtures.channel(61, "Clockwork Corner")])
        )
        await board.loadChannels()
        XCTAssertEqual(board.caption, "2 channels")
        XCTAssertEqual(board.channels.map(\.id), [60, 61])
    }

    private func routeTwoPages(watched: Bool) {
        transport.respond = { sent in
            guard sent.path == "/youtube/videos" else { return nil }
            if sent.query.contains("offset=100") {
                return (.ok, Fixtures.page([Fixtures.video(71, "Second page", watched: watched)]))
            }
            let first = Fixtures.page([Fixtures.video(70, "First page", watched: watched)], total: 2)
            return (.ok, first.replacingOccurrences(of: #""total":2}"#, with: #""total":2,"nextOffset":100}"#))
        }
    }

    func testRefreshRereadsTheLoadedPagesInPlace() async {
        routeTwoPages(watched: false)
        await board.load(.videos, sort: .newest, channel: nil)
        await board.videos?.loadMore()
        XCTAssertEqual(board.videos?.items.map(\.id), [70, 71])
        let shown = board.videos
        routeTwoPages(watched: true)
        await board.refresh(.videos)
        XCTAssertTrue(board.videos === shown)
        XCTAssertEqual(board.videos?.items.map(\.id), [70, 71])
        XCTAssertEqual(board.videos?.items.map(\.watched), [true, true])
    }

    func testChangingTheSortStartsOverFromTheFirstPage() async {
        transport.routes["GET /youtube/videos"] = (.ok, Fixtures.page([Fixtures.video(70, "A")]))
        await board.load(.videos, sort: .newest, channel: nil)
        let shown = board.videos
        await board.load(.videos, sort: .title, channel: nil)
        XCTAssertFalse(board.videos === shown)
        XCTAssertEqual(
            transport.queries(.get, "/youtube/videos"),
            ["sort=newest&limit=100", "sort=title&limit=100"])
    }
}
