import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

extension Fixtures {
    static func video(
        _ id: Int64, _ title: String, channel: Int64 = 60, published: String = "2026-11-14",
        durationMs: Int64 = 2_520_000, watched: Bool = false, position: Int64 = 0, played: String? = nil
    ) -> String {
        #"{"id":\#(id),"libraryId":4,"channelId":\#(channel),"channelTitle":"Workbench Weekly","#
            + #""title":"\#(title)","durationMs":\#(durationMs),"publishedOn":"\#(published)","height":1080,"#
            + #""watched":\#(watched),"positionMs":\#(position),"#
            + (played.map { #""lastPlayedAt":"\#($0)","# } ?? "") + #""addedAt":"2026-11-14T06:12:00Z"}"#
    }

    static func channel(_ id: Int64, _ title: String, videos: Int = 214, unwatched: Int = 12) -> String {
        #"{"id":\#(id),"libraryId":4,"title":"\#(title)","videoCount":\#(videos),"#
            + #""unwatchedCount":\#(unwatched),"lastVideoOn":"2026-11-14","#
            + #""addedAt":"2026-01-01T00:00:00Z"}"#
    }
}

@MainActor
final class YouTubeModelTests: XCTestCase {
    var transport: RoutingTransport!
    var model: YouTubeModel!

    override func setUp() async throws {
        transport = RoutingTransport()
        model = YouTubeModel(
            client: ServerEndpoint(userInput: "192.168.1.9")!.client(token: "t", transport: transport),
            profileId: 1)
    }

    func testNewFromYourChannelsIsTheNewestUnwatched() async throws {
        transport.routes["GET /youtube/videos"] = (.ok, Fixtures.page([Fixtures.video(70, "The dishwasher video")]))
        let videos = try await model.newFromChannels()
        XCTAssertEqual(videos.map(\.title), ["The dishwasher video"])
        XCTAssertEqual(transport.queries(.get, "/youtube/videos"), ["unwatched=true&sort=newest&limit=20"])
    }

    func testInProgressIsLatestPlayedFirst() async throws {
        transport.routes["GET /youtube/videos"] = (.ok, Fixtures.page([Fixtures.video(70, "x", position: 9)]))
        let videos = try await model.inProgress()
        XCTAssertEqual(videos.map(\.id), [70])
        XCTAssertEqual(transport.queries(.get, "/youtube/videos"), ["inProgress=true&sort=played&limit=20"])
    }

    func testVideosPassTheChipsSortAndChannel() async throws {
        transport.routes["GET /youtube/videos"] = (.ok, Fixtures.page([]))
        _ = try await model.videos(sort: .oldest, channelId: 60, unwatched: true)
        _ = try await model.videos(offset: 100)
        XCTAssertEqual(
            transport.queries(.get, "/youtube/videos"),
            [
                "channelId=60&unwatched=true&sort=oldest&limit=100",
                "sort=newest&limit=100&offset=100",
            ]
        )
    }

    func testChannelsReadEveryPage() async throws {
        transport.respond = { sent in
            switch (sent.path, sent.query.contains("offset=200")) {
            case ("/youtube/channels", false):
                (.ok, #"{"items":[\#(Fixtures.channel(60, "Workbench Weekly"))],"nextOffset":200}"#)
            case ("/youtube/channels", true): (.ok, Fixtures.page([Fixtures.channel(61, "Clockwork Corner")]))
            default: nil
            }
        }
        let channels = try await model.channels(sort: .latest)
        XCTAssertEqual(channels.map(\.id), [60, 61])
        XCTAssertEqual(
            transport.queries(.get, "/youtube/channels"), ["sort=latest&limit=200", "sort=latest&limit=200&offset=200"])
    }

    func testChannelHasItsVideosNewestFirst() async throws {
        transport.routes = [
            "GET /youtube/channels/60": (.ok, Fixtures.channel(60, "Workbench Weekly")),
            "GET /youtube/videos": (.ok, Fixtures.page([Fixtures.video(70, "The dishwasher video")])),
        ]
        let detail = try await model.channel(60)
        XCTAssertEqual(detail.channel.title, "Workbench Weekly")
        XCTAssertEqual(detail.videos.map(\.id), [70])
        XCTAssertEqual(transport.queries(.get, "/youtube/videos"), ["channelId=60&sort=newest&limit=200"])
    }

    func testVideoHasMoreFromItsChannelWithoutItself() async throws {
        transport.routes = [
            "GET /youtube/videos/70": (.ok, Fixtures.video(70, "The dishwasher video")),
            "GET /youtube/videos": (
                .ok,
                Fixtures.page([
                    Fixtures.video(70, "The dishwasher video"), Fixtures.video(71, "How CRTs actually work"),
                ])
            ),
        ]
        let detail = try await model.video(70)
        XCTAssertEqual(detail.video.title, "The dishwasher video")
        XCTAssertEqual(detail.moreFromChannel.map(\.id), [71])
        XCTAssertEqual(transport.queries(.get, "/youtube/videos"), ["channelId=60&sort=newest&limit=13"])
    }

    func testMarkAllWatchedWritesTheChannelForTheProfile() async throws {
        transport.routes["PUT /profiles/1/youtube/channels/60/watch-state"] = (.noContent, "")
        try await model.setWatched(true, channel: 60)
        XCTAssertEqual(transport.json(.put, "/profiles/1/youtube/channels/60/watch-state")?["watched"] as? Bool, true)
    }

    func testAKidsForbiddenWriteThrowsTheServersMessage() async {
        transport.routes["PUT /profiles/1/youtube/channels/60/watch-state"] = (
            .forbidden, Fixtures.error("forbidden", "Kids see no YouTube.")
        )
        do {
            try await model.setWatched(true, channel: 60)
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? AppError, .server("Kids see no YouTube."))
        }
    }

    func testForKidsIsSetOnTheChannel() async throws {
        transport.routes["PUT /youtube/channels/60/for-kids"] = (
            .ok, String(Fixtures.channel(60, "Workbench Weekly").dropLast()) + #","forKids":true}"#
        )
        let channel = try await model.setForKids(true, channel: 60)
        XCTAssertEqual(channel.forKids, true)
        XCTAssertEqual(transport.json(.put, "/youtube/channels/60/for-kids")?["forKids"] as? Bool, true)
    }
    func testAVideoPlaysAsAnItemWithItsTitleAndLength() {
        let item = Item(video: Fixtures.decode(Fixtures.video(70, "The dishwasher video"), as: YouTubeVideo.self))
        XCTAssertEqual(item.id, 70)
        XCTAssertEqual(Catalog.title(item), "The dishwasher video")
        XCTAssertEqual(item.metadata?.runtimeMinutes, 42)
    }

    func testPublishedReadsAsTheBoardsSay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = ISO8601DateFormatter().date(from: "2026-11-14T18:00:00Z")!
        let cases = [
            "2026-11-14": "today", "2026-11-13": "yesterday", "2026-11-11": "3 days ago", "2026-11-07": "last week",
            "2026-10-31": "2 weeks ago", "2026-10-10": "last month", "2026-08-01": "3 months ago",
            "2025-10-01": "last year", "2023-01-01": "3 years ago", "2026-11-20": "today", "garbage": "",
        ]
        for (day, want) in cases {
            XCTAssertEqual(Format.published(day, now: now, calendar: calendar), want, day)
        }
        let video = Fixtures.decode(Fixtures.video(70, "x", published: "2026-11-13"), as: YouTubeVideo.self)
        XCTAssertEqual(Format.video(video, now: now, calendar: calendar), "42m · yesterday")
    }
}
