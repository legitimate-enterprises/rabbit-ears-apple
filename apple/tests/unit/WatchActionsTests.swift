import Foundation
import GRDB
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// Each watch-state action leaves the row the server's watch-state
/// repository stores, and queues the call that replays it.
final class WatchActionsTests: ActionQueueCase {
    /// The queue's now, as the replica stores it.
    let now = ActionQueue.ms(ActionQueueCase.now)

    /// Avery an adult (1) and Kit a kid to TV-PG (3). Dune (20) has a tagged
    /// cut on disk (5), an untagged one gone (6) and an untagged one on disk
    /// (7). Alpha (10) is TV-PG and Night (16) TV-MA; Shop (50) is a kids'
    /// channel; an album (60) is not watched.
    private func library(_ rows: (Database) throws -> Void = { _ in }) throws -> Replica {
        try fixture.v1 { db in
            try db.account(1, "Avery")
            try db.account(3, "Kit", kind: "kid", movies: "PG", tv: "TV-PG")
            try db.item(20, "movie", "Dune", rating: "PG-13")
            try db.edition(5, of: 20, tag: "Extended")
            try db.file(50, in: 5)
            try db.edition(6, of: 20)
            try db.file(60, in: 6, missing: true)
            try db.edition(7, of: 20)
            try db.file(70, in: 7)
            try db.item(10, "show", "Alpha", rating: "TV-PG")
            try db.item(11, "season", "Season 1", parent: 10, season: 1, rating: "TV-PG")
            try db.item(13, "episode", "Second", parent: 11, season: 1, episode: 2, rating: "TV-PG")
            try db.item(12, "episode", "Pilot", parent: 11, season: 1, episode: 1, rating: "TV-PG")
            try db.item(14, "season", "Season 2", parent: 10, season: 2)
            try db.item(15, "episode", "Dark", parent: 14, season: 2, episode: 1)
            try db.item(16, "show", "Night", rating: "TV-MA")
            try db.item(17, "season", "Season 1", parent: 16, season: 1)
            try db.item(18, "episode", "Late", parent: 17, season: 1, episode: 1)
            try db.library(2, "youtube")
            try db.execute(
                sql: """
                    INSERT INTO item(id, library_id, parent_id, kind, parsed_title, added_at) VALUES
                        (\(sqlID(50)), \(sqlID(2)), NULL, 'channel', 'Shop', 0),
                        (\(sqlID(52)), \(sqlID(2)), \(sqlID(50)), 'video', 'B', 0),
                        (\(sqlID(51)), \(sqlID(2)), \(sqlID(50)), 'video', 'A', 0);
                    UPDATE item SET kids_content = 1 WHERE id = \(sqlID(50));
                    INSERT INTO item(id, library_id, kind, parsed_title, added_at)
                        VALUES (\(sqlID(60)), \(sqlID(1)), 'album', 'Hits', 0);
                    """)
            try rows(db)
        }
    }

    /// position, watched, play count, last played, changed, and the edition as its uid.N number.
    private func state(_ replica: Replica, _ item: UID, for profile: UID = 1) async throws -> [Int64?]? {
        try await replica.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT position_ms, watched, play_count, last_played_at, changed_at, edition_id FROM watch_state
                    WHERE account_id = ? AND item_id = ?
                    """, arguments: [profile, item]
            ).map { row in
                (0..<5).map { row[$0] as Int64? }
                    + [(row[5] as UID?).map { Int64(String($0.description.suffix(12)), radix: 16)! }]
            }
        }
    }

    /// A stored state: position, watched, play count, last played, changed, edition uid.N(n).
    private func store(_ item: UID, _ values: [Int64?], for profile: UID = 1) -> (Database) throws -> Void {
        { db in
            var cells: [(any DatabaseValueConvertible)?] = [profile, item]
            cells += values.prefix(5).map { $0 }
            cells.append(values[5].map { UID.n(Int($0)) })
            try db.execute(
                sql: "INSERT INTO watch_state VALUES (?, ?, ?, ?, ?, ?, ?, ?)", arguments: StatementArguments(cells))
        }
    }

    private func sent() -> [[String: Any]] {
        transport.json(.post, "/sync/actions")?["actions"] as? [[String: Any]] ?? []
    }

    func testAMarkResumesInTheDefaultCutAndCountsAPlayWhenItBecomesWatched() async throws {
        let replica = try library()
        let queue = queue(replica)
        try await queue.putWatchState(false, positionMs: 600_123, item: 20, as: 1)
        let resumed = try await state(replica, 20)
        XCTAssertEqual(resumed, [600_123, 0, 0, now, now, 7], "the untagged cut on disk")
        try await queue.putWatchState(true, edition: 5, item: 20, as: 1)
        let watched = try await state(replica, 20)
        XCTAssertEqual(watched, [0, 1, 1, now, now, 5])
        try await queue.putWatchState(true, item: 20, as: 1)
        let again = try await state(replica, 20)
        XCTAssertEqual(again, [0, 1, 1, now, now, 7], "already watched is no new play")

        _ = await queue.flush()
        XCTAssertEqual(
            sent().map { $0["path"] as? String },
            Array(repeating: "/profiles/\(UID.n(1))/watch-state/\(UID.n(20))", count: 3))
        let body = sent().first?["body"] as? [String: Any]
        XCTAssertEqual(body?["watched"] as? Bool, false)
        XCTAssertEqual(body?["positionMs"] as? Int, 600_123)
        XCTAssertNil(body?["editionId"])
        XCTAssertEqual(body?["at"] as? String, "2027-01-15T08:00:00.123Z")
        let queued = try await queued(replica)
        XCTAssertEqual(queued, [])
    }

    func testAMarkOverAStateChangedLaterChangesNothing() async throws {
        let later = now + 1
        let replica = try library(store(20, [42, 0, 3, later, later, 6]))
        try await queue(replica).putWatchState(true, item: 20, as: 1)
        let kept = try await state(replica, 20)
        XCTAssertEqual(kept, [42, 0, 3, later, later, 6])
    }

    func testASelectionMarksEachEpisodeTheProfileMaySeeEachVideoAndKeepsTheCut() async throws {
        let replica = try library(store(12, [42, 0, 2, 9, 9, 5], for: 3))
        let queue = queue(replica)
        try await queue.putWatchStates(true, items: [10, 50, 12], as: 3, in: replica)
        let episode = try await state(replica, 12, for: 3)
        XCTAssertEqual(episode, [0, 1, 3, now, now, 5])
        let fresh = try await state(replica, 13, for: 3)
        XCTAssertEqual(fresh, [0, 1, 1, now, now, nil])
        let later = try await state(replica, 15, for: 3)
        XCTAssertEqual(later?[1], 1)
        let video = try await state(replica, 51, for: 3)
        XCTAssertEqual(video?[1], 1)

        _ = await queue.flush()
        XCTAssertEqual(sent().map { $0["path"] as? String }, ["/profiles/\(UID.n(3))/watch-state/batch"])
        let body = sent().first?["body"] as? [String: Any]
        XCTAssertEqual(
            body?["itemIds"] as? [String], [12, 13, 15, 51, 52].map { "\(UID.n($0))" }, "each once, episodes by number")
        XCTAssertEqual(body?["watched"] as? Bool, true)
    }

    func testALargeSelectionGoesInActionsOfAtMostTheTouchedLimit() async throws {
        let replica = try library { db in
            for number in 1...(ActionQueue.touchedLimit + 6) {
                try db.item(UID.n(1000 + number), "episode", "E\(number)", parent: 11, season: 1, episode: number)
            }
        }
        try await queue(replica).putWatchStates(false, items: [11], as: 1, in: replica)
        let touched = try await replica.read {
            try Int.fetchAll($0, sql: "SELECT COUNT(*) FROM queue.action_touch GROUP BY action ORDER BY action")
        }
        XCTAssertEqual(touched, [ActionQueue.touchedLimit, 8])
    }

    func testASelectionWithATitleTheProfileMayNotSeeOrAnAlbumQueuesNothing() async throws {
        let replica = try library()
        let queue = queue(replica)
        do {
            try await queue.putWatchStates(true, items: [12, 18], as: 3, in: replica)
            XCTFail("Night is past Kit's ceiling")
        } catch ActionQueue.WatchRefusal.notFound {}
        do {
            try await queue.putWatchStates(true, items: [60], as: 1, in: replica)
            XCTFail("albums are not watched")
        } catch ActionQueue.WatchRefusal.notWatchable {}
        let pilot = try await state(replica, 12, for: 3)
        XCTAssertNil(pilot)
        let queued = try await queued(replica)
        XCTAssertEqual(queued, [])
    }

    func testForgettingKeepsAStateChangedLater() async throws {
        let replica = try library { db in
            try self.store(20, [1, 0, 1, 1, self.now, 7])(db)
            try self.store(12, [1, 0, 1, 1, self.now + 1, nil])(db)
        }
        let queue = queue(replica)
        try await queue.deleteWatchState(item: 20, as: 1)
        try await queue.deleteWatchState(item: 12, as: 1)
        let forgotten = try await state(replica, 20)
        XCTAssertNil(forgotten)
        let kept = try await state(replica, 12)
        XCTAssertNotNil(kept)
        _ = await queue.flush()
        XCTAssertEqual(
            sent().first?["path"] as? String,
            "/profiles/\(UID.n(1))/watch-state/\(UID.n(20))?at=2027-01-15T08%3A00%3A00.123Z")
    }

    func testAPlayAddsOneKeepsTheLaterLastPlayAndWatchesOnlyOverAnOlderState() async throws {
        let earlier = now - 60_000
        let replica = try library { db in
            try self.store(20, [500, 0, 2, self.now, earlier, 5])(db)
            try self.store(12, [500, 0, 2, earlier, self.now + 5, 5])(db)
        }
        let queue = queue(replica)
        let ended = Date(timeIntervalSince1970: Double(earlier + 1000) / 1000)
        try await queue.recordPlay(item: 20, edition: nil, as: 1, at: ended)
        let older = try await state(replica, 20)
        XCTAssertEqual(older, [0, 1, 3, now, earlier + 1000, 7], "the default cut, the later last play")
        try await queue.recordPlay(item: 12, edition: 6, as: 1, at: ended)
        let newer = try await state(replica, 12)
        XCTAssertEqual(newer, [500, 0, 3, earlier + 1000, now + 5, 5])
        try await queue.recordPlay(item: 13, edition: nil, as: 1, at: .distantFuture)
        let ahead = try await state(replica, 13)
        XCTAssertEqual(ahead, [0, 1, 1, now, now, nil], "a time ahead is now; no cut has a file")

        _ = await queue.flush()
        let body = sent().first?["body"] as? [String: Any]
        XCTAssertEqual(sent().first?["path"] as? String, "/profiles/\(UID.n(1))/watch-state/\(UID.n(20))/plays")
        XCTAssertNil(body?["editionId"])
        XCTAssertNotNil(body?["at"])
    }
}
