import Foundation
import GRDB
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

extension Fixtures {
    static func video(
        _ id: UID, _ title: String, channel: UID = 60, published: String = "2026-11-14",
        durationMs: Int64 = 2_520_000, watched: Bool = false, position: Int64 = 0, played: String? = nil
    ) -> String {
        #"{"id":"\#(id)","libraryId":"\#(UID.n(4))","channelId":"\#(channel)","channelTitle":"Workbench Weekly","#
            + #""title":"\#(title)","durationMs":\#(durationMs),"publishedOn":"\#(published)","height":1080,"#
            + #""watched":\#(watched),"positionMs":\#(position),"#
            + (played.map { #""lastPlayedAt":"\#($0)","# } ?? "") + #""addedAt":"2026-11-14T06:12:00Z"}"#
    }

    static func channel(_ id: UID, _ title: String, videos: Int = 214, unwatched: Int = 12) -> String {
        #"{"id":"\#(id)","libraryId":"\#(UID.n(4))","title":"\#(title)","videoCount":\#(videos),"#
            + #""unwatchedCount":\#(unwatched),"lastVideoOn":"2026-11-14","#
            + #""addedAt":"2026-01-01T00:00:00Z"}"#
    }
}

@MainActor
final class YouTubeModelTests: XCTestCase {
    var transport: RoutingTransport!
    var fixture: ReplicaFixture!
    let gate = Latch()

    override func setUp() async throws {
        transport = RoutingTransport()
        fixture = ReplicaFixture()
    }

    override func tearDown() async throws {
        gate.close()
        fixture.remove()
    }

    /// Avery an adult (1), Robin hiding kids' content (2) and Kit a kid (3).
    /// Workbench Weekly (60) has three videos, Clockwork Corner (61) is for
    /// kids, Empty (62) has none and Mixtapes (63) is a YouTube playlist.
    /// Avery watched 71 and is part way through 70 and 73.
    private func library(_ rows: @escaping (Database) throws -> Void = { _ in }) throws -> Replica {
        try fixture.v1 { db in
            try db.preferLocal()
            try db.account(1, "Avery")
            try db.account(2, "Robin", hidingKids: true)
            try db.account(3, "Kit", kind: "kid", movies: "PG", tv: "TV-Y")
            try db.library(4, "youtube")
            try db.channel(60, "Workbench Weekly", kids: false, external: "UCwork", overview: "Shop talk.")
            try db.channel(61, "Clockwork Corner", kids: true)
            try db.channel(62, "Empty")
            try db.channel(63, "Mixtapes", external: "PLabc")
            try db.video(
                70, "The dishwasher video", channel: 60, published: "2026-11-14T09:00:00Z", external: "vid70",
                overview: "Bosch.", durationMs: 2_520_000, height: 1080, added: "2026-11-14T06:12:00Z")
            try db.video(
                71, "How CRTs actually work", channel: 60, published: "2026-11-10T00:00:00Z", durationMs: 600_000)
            try db.video(72, "Unpublished", channel: 60, added: "2026-11-20T00:00:00Z")
            try db.video(73, "Gears", channel: 61, published: "2026-11-12T00:00:00Z", durationMs: 900_000)
            try db.video(74, "Side A", channel: 63, published: "2026-11-01T00:00:00Z")
            try db.watch(71, for: 1, watched: true)
            try db.watch(70, for: 1, position: 60_000, played: "2026-11-20T00:00:00Z")
            try db.watch(73, for: 1, position: 5_000, played: "2026-11-21T00:00:00Z")
            try rows(db)
        }
    }

    private func model(_ replica: Replica, _ profile: UID = 1) -> YouTubeModel {
        let client = ServerEndpoint(userInput: "192.168.1.9")!.client(token: "t", transport: transport)
        let gate = gate
        return YouTubeModel(
            client: client, replica: replica,
            queue: ActionQueue(replica: replica, client: client, debounce: { await gate.wait() }), profileId: profile)
    }

    private func at(_ instant: String) -> Date { ISO8601DateFormatter().date(from: instant)! }

    func testNewFromYourChannelsIsTheNewestUnwatched() async throws {
        let videos = try await model(library()).newFromChannels()
        XCTAssertEqual(videos.map(\.id), [70, 73, 74, 72], "the watched one left out, the unpublished last")
        XCTAssertTrue(transport.sent.isEmpty, "read from the replica")
    }

    func testInProgressIsLatestPlayedFirst() async throws {
        let videos = try await model(library()).inProgress()
        XCTAssertEqual(videos.map(\.id), [73, 70])
    }

    func testAVideoCarriesItsChannelFileAndTheProfilesWatchState() async throws {
        let video = try await model(library()).video(70).video
        XCTAssertEqual(
            video,
            YouTubeVideo(
                id: 70, libraryId: 4, channelId: 60, channelTitle: "Workbench Weekly", title: "The dishwasher video",
                overview: "Bosch.", durationMs: 2_520_000, publishedOn: "2026-11-14", height: 1080, watched: false,
                positionMs: 60_000, lastPlayedAt: at("2026-11-20T00:00:00Z"), externalId: "vid70",
                sourceUrl: "https://www.youtube.com/watch?v=vid70", addedAt: at("2026-11-14T06:12:00Z")))
        let other = try await model(library(), 2).video(70).video
        XCTAssertEqual([other.positionMs], [0], "Robin's own state")
    }

    func testVideosSortFilterAndPageAsTheServerDoes() async throws {
        let youTube = model(try library())
        let orders: [(YouTubeVideoSort, [UID])] = [
            (.newest, [70, 73, 71, 74, 72]), (.oldest, [74, 71, 73, 70, 72]), (.title, [73, 71, 74, 70, 72]),
            (.channel, [73, 74, 70, 71, 72]), (.length, [70, 73, 71, 72, 74]), (.played, [73, 70, 71, 72, 74]),
        ]
        for (sort, ids) in orders {
            let page = try await youTube.videos(sort: sort)
            XCTAssertEqual(page.items.map(\.id), ids, sort.rawValue)
        }
        let channel = try await youTube.videos(sort: .oldest, channelId: 60, unwatched: true)
        XCTAssertEqual(channel.items.map(\.id), [70, 72])
        let found = try await youTube.videos(query: "crt")
        XCTAssertEqual(found.items.map(\.id), [71])
        let first = try await youTube.videos(limit: 2)
        XCTAssertEqual(first.items.map(\.id), [70, 73])
        XCTAssertEqual(first.nextOffset, 2)
        let last = try await youTube.videos(offset: 4, limit: 2)
        XCTAssertEqual(last.items.map(\.id), [72])
        XCTAssertNil(last.nextOffset)
    }

    func testTheDownloadedFilterKeepsWhatIsPlayableHereAlongsideUnwatched() async throws {
        let youTube = model(try library())
        let kept: Set<UID> = [70, 71, 60]
        let here = try await youTube.videos(onDevice: kept)
        XCTAssertEqual(here.items.map(\.id), [70, 71])
        let unwatched = try await youTube.videos(unwatched: true, onDevice: kept)
        XCTAssertEqual(unwatched.items.map(\.id), [70])
        let none = try await youTube.videos(onDevice: [])
        XCTAssertEqual(none.items.map(\.id), [])
        let off = try await youTube.videos()
        XCTAssertEqual(off.items.count, 5, "off, every video")
    }

    func testChannelsWithVideosCountTheProfilesUnwatched() async throws {
        let youTube = model(try library())
        let channels = try await youTube.channels()
        XCTAssertEqual(channels.map(\.id), [61, 63, 60], "by title; Empty has no videos")
        XCTAssertEqual(
            channels[2],
            YouTubeChannel(
                id: 60, libraryId: 4, title: "Workbench Weekly", overview: "Shop talk.", videoCount: 3,
                unwatchedCount: 2, lastVideoOn: "2026-11-14", externalId: "UCwork",
                sourceUrl: "https://www.youtube.com/channel/UCwork", forKids: false, addedAt: at("2026-01-01T00:00:00Z")
            ))
        XCTAssertEqual(channels[1].sourceUrl, "https://www.youtube.com/playlist?list=PLabc")
        XCTAssertEqual(channels[0].forKids, true)
        let latest = try await youTube.channels(sort: .latest)
        XCTAssertEqual(latest.map(\.id), [60, 61, 63])
    }

    func testChannelHasItsVideosInTheChosenOrderAndAnEmptyOneIsFound() async throws {
        let youTube = model(try library())
        let detail = try await youTube.channel(60)
        XCTAssertEqual(detail.channel.title, "Workbench Weekly")
        XCTAssertEqual(detail.videos.map(\.id), [70, 71, 72])
        let oldest = try await youTube.channel(60, sort: .oldest)
        XCTAssertEqual(oldest.videos.map(\.id), [71, 70, 72])
        let empty = try await youTube.channel(62)
        XCTAssertEqual([empty.channel.videoCount, empty.videos.count], [0, 0])
    }

    func testVideoHasMoreFromItsChannelWithoutItself() async throws {
        let detail = try await model(library()).video(71)
        XCTAssertEqual(detail.moreFromChannel.map(\.id), [70, 72])
    }

    func testAKidSeesOnlyChannelsForKidsAndHidingKidsBrowsesWithoutThem() async throws {
        let replica = try library()
        let kid = model(replica, 3)
        let kidChannels = try await kid.channels()
        XCTAssertEqual(kidChannels.map(\.id), [61])
        let kidVideos = try await kid.videos()
        XCTAssertEqual(kidVideos.items.map(\.id), [73])
        do {
            _ = try await kid.video(70)
            XCTFail("a video the kid may not see is not found")
        } catch {
            XCTAssertEqual(error as? AppError, .server("not found"))
        }
        let robin = model(replica, 2)
        let robinChannels = try await robin.channels()
        XCTAssertEqual(robinChannels.map(\.id), [63, 60])
        let opened = try await robin.video(73)
        XCTAssertEqual(opened.video.id, 73, "opened directly, as the server answers it")
        XCTAssertEqual(opened.moreFromChannel.map(\.id), [], "but not browsed")
    }

    func testMarkAllWatchedMarksEachVideoAtOnceAndQueuesTheChannelsCall() async throws {
        let replica = try library { db in
            // A change made after this one, on another device, stands.
            try db.execute(
                sql: "UPDATE watch_state SET changed_at = ? WHERE account_id = \(sqlID(1)) AND item_id = \(sqlID(70))",
                arguments: [Database.ms("2100-01-01T00:00:00Z")])
        }
        let youTube = model(replica)
        try await youTube.setWatched(true, channel: 60)
        XCTAssertTrue(transport.sent.isEmpty, "queued, not sent")
        let rows = try await replica.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT watched, position_ms, play_count, last_played_at = changed_at AS stamped
                    FROM watch_state WHERE account_id = \(sqlID(1))
                        AND item_id IN (\(sqlID(70)), \(sqlID(71)), \(sqlID(72))) ORDER BY item_id
                    """
            ).map { [$0["watched"], $0["position_ms"], $0["play_count"], $0["stamped"]] as [Int64] }
        }
        XCTAssertEqual(rows[0], [0, 60_000, 0, 0], "70 keeps the later change")
        XCTAssertEqual(rows[1], [1, 0, 0, 1], "an already watched one counts no play")
        XCTAssertEqual(rows[2], [1, 0, 1, 1])
        let action = try await replica.read { db in
            try Row.fetchOne(db, sql: "SELECT operation_id, path, body FROM queue.action").map {
                ($0["operation_id"] as String, $0["path"] as String, $0["body"] as Data)
            }
        }
        XCTAssertEqual(action?.0, "putYouTubeChannelWatchState")
        XCTAssertEqual(action?.1, "/profiles/\(UID.n(1))/youtube/channels/\(UID.n(60))/watch-state")
        let body = try JSONSerialization.jsonObject(with: action?.2 ?? Data()) as? [String: Any]
        XCTAssertEqual(body?["watched"] as? Bool, true)
        XCTAssertNotNil(body?["at"])
        let touched = try await replica.read { db in
            try Row.fetchAll(db, sql: "SELECT table_name, key1, key2 FROM queue.action_touch ORDER BY key2")
                .map { "\($0["table_name"] as String) \($0["key1"] as String) \($0["key2"] as String)" }
        }
        XCTAssertEqual(touched, [70, 71, 72].map { "watch_state \(UID.n(1)) \(UID.n($0))" })
        let channel = try await youTube.channel(60).channel
        XCTAssertEqual(channel.unwatchedCount, 1)
        try await youTube.setWatched(false, channel: 60)
        let after = try await youTube.channel(60).channel
        XCTAssertEqual(after.unwatchedCount, 3, "70 was never marked; 71 and 72 are unmarked")
    }

    private let channelWatchState = "/profiles/\(UID.n(1))/youtube/channels/\(UID.n(60))/watch-state"

    /// More videos than an action may name go to the server at once, as before.
    private func bigChannel() throws -> Replica {
        try library { db in
            for number in 1000..<(1000 + ActionQueue.touchedLimit) {
                try db.video(.n(number), "Clip \(number)", channel: 60)
            }
        }
    }

    func testMarkingAChannelTooBigToQueueIsSentAtOnce() async throws {
        transport.routes["PUT \(channelWatchState)"] = (.noContent, "")
        let replica = try bigChannel()
        try await model(replica).setWatched(true, channel: 60)
        XCTAssertEqual(transport.json(.put, channelWatchState)?["watched"] as? Bool, true)
        let queued = try await replica.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM queue.action") }
        XCTAssertEqual(queued, 0)
    }

    func testAForbiddenChannelMarkSentAtOnceThrowsTheServersMessage() async throws {
        transport.routes["PUT \(channelWatchState)"] = (
            .forbidden, Fixtures.error("forbidden", "Kids see no YouTube.")
        )
        do {
            try await model(bigChannel()).setWatched(true, channel: 60)
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? AppError, .server("Kids see no YouTube."))
        }
    }

    func testForKidsIsSetOnTheChannelThroughTheQueue() async throws {
        let replica = try library()
        let model = model(replica)
        try await model.setForKids(true, channel: 60)
        let detail = try await model.channel(60)
        XCTAssertEqual(detail.channel.forKids, true)
        let queued = try await replica.read {
            try String.fetchAll($0, sql: "SELECT operation_id || ' ' || path FROM queue.action")
        }
        XCTAssertEqual(queued, ["setYouTubeChannelForKids /youtube/channels/\(UID.n(60))/for-kids"])
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
