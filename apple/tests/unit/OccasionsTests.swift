import Foundation
import GRDB
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// Avery an adult (1) and Kit a kid to PG (3). Christmas holds 25 films
/// Kit may see, one of them removed by hand and one by keyword; Halloween
/// Nights a show only Avery may see; New Year's window reaches back into
/// December; Leap Day falls only in leap years.
@MainActor
class OccasionCase: XCTestCase {
    var fixture: ReplicaFixture!
    let eastern = TimeZone(identifier: "America/New_York")!
    let utc = TimeZone(identifier: "UTC")!

    override func setUp() { fixture = ReplicaFixture() }
    override func tearDown() { fixture.remove() }

    func seasons(_ rows: (Database) throws -> Void = { _ in }) throws -> Replica {
        try fixture.v1 { db in
            try db.account(1, "Avery")
            try db.account(3, "Kit", kind: "kid", movies: "PG")
            // Titles run against ids, so title order shows.
            for id in 101...125 { try db.item(.n(id), "movie", "Elf \(226 - id)", rating: "PG") }
            try db.item(126, "movie", "Elf Gone", rating: "PG")
            try db.item(127, "movie", "A Keyworded Elf", rating: "PG")
            try db.item(200, "show", "Spooky", rating: "TV-MA")
            try db.item(300, "movie", "Ball Drop", rating: "PG")
            try db.holiday("christmas", on: ["2025-12-25", "2026-12-25", "2027-12-25"])
            try db.holiday("new-years-day", on: ["2026-01-01", "2027-01-01"])
            try db.occasion(
                Self.christmas, "Christmas", holiday: "christmas", before: 30, after: 5,
                members: (101...126).map(UID.n),
                phrases: ["Ho, Ho, Ho!"], colors: ["#C8102E", "#00843D", "#FFD100"])
            try db.execute(
                sql: "INSERT INTO occasion_exclusion(occasion_id, item_id) VALUES (?, ?)",
                arguments: [Self.christmas, UID.n(126)])
            try db.execute(
                sql: "INSERT INTO occasion_keyword(occasion_id, keyword_id) VALUES (?, 9)", arguments: [Self.christmas])
            try db.execute(sql: "INSERT INTO item_keyword(item_id, keyword_id) VALUES (?, 9)", arguments: [UID.n(127)])
            try db.occasion(
                Self.halloween, "Halloween  Nights", month: 10, day: 31, before: 30, after: 1, members: [200])
            try db.occasion(3, "New Year", holiday: "new-years-day", before: 10, after: 0, members: [300])
            try db.occasion(4, "Leap Day", month: 2, day: 29, before: 0, after: 0, members: [300])
            try rows(db)
        }
    }

    func at(_ instant: String) -> Date { ISO8601DateFormatter().date(from: instant)! }

    /// The server seeds Christmas and Halloween under ids of their own, never small integers.
    nonisolated static let christmas = UID("00000000-0000-7000-9000-000000000001")!
    nonisolated static let halloween = UID("00000000-0000-7000-9000-000000000002")!
}

final class OccasionsModelTests: OccasionCase {
    func testTheOccasionsInSeasonAreNearestTheirAnchorFirstEachWithItsFirstTitles() async throws {
        let model = OccasionsModel()
        await model.load(replica: try seasons(), profileId: 1, now: at("2026-12-24T15:00:00Z"), timeZone: eastern)
        XCTAssertTrue(model.answered)
        XCTAssertEqual(model.shelves.map(\.name), ["Christmas", "New Year"], "1 day off, then 8")
        let christmas = try XCTUnwrap(model.shelves.first)
        XCTAssertEqual(christmas.items.count, Catalog.homeShelfLimit)
        XCTAssertEqual(christmas.items.prefix(3).map(\.id), [127, 125, 124], "by title, the keyworded one too")
        XCTAssertFalse(christmas.items.contains { $0.id == 126 }, "removed by hand")
        XCTAssertEqual(christmas.title, "Ho, Ho, Ho!")
        XCTAssertEqual(christmas.occasion.colors, ["#C8102E", "#00843D", "#FFD100"])
        XCTAssertEqual(
            [christmas.occasion.anchorDate, christmas.occasion.firstDate, christmas.occasion.lastDate],
            ["2026-12-25", "2026-11-25", "2026-12-30"])
        let newYear = model.shelves[1].occasion
        XCTAssertEqual(newYear.rowTitle, "New Year", "no phrase")
        XCTAssertNil(newYear.colors)
        XCTAssertEqual([newYear.anchorDate, newYear.firstDate], ["2027-01-01", "2026-12-22"])
    }

    func testTheDeviceDayDecidesWhatIsInSeason() async throws {
        let replica = try seasons()
        let model = OccasionsModel()
        // 03:30 UTC on the 25th is still the 24th in New York, a day before Christmas's window.
        await model.load(replica: replica, profileId: 1, now: at("2026-11-25T03:30:00Z"), timeZone: eastern)
        XCTAssertEqual(model.shelves.map(\.name), [])
        await model.load(replica: replica, profileId: 1, now: at("2026-11-25T03:30:00Z"), timeZone: utc)
        XCTAssertEqual(model.shelves.map(\.name), ["Christmas"])
        await model.load(replica: replica, profileId: 1, now: at("2026-10-20T12:00:00Z"), timeZone: utc)
        XCTAssertEqual(model.shelves.map(\.name), ["Halloween  Nights"])
    }

    func testAnOccasionWithNothingTheProfileBrowsesIsNotInSeason() async throws {
        let model = OccasionsModel()
        await model.load(replica: try seasons(), profileId: 3, now: at("2026-10-20T12:00:00Z"), timeZone: utc)
        XCTAssertTrue(model.answered)
        XCTAssertTrue(model.shelves.isEmpty, "Spooky is past Kit's ceiling")
    }

    func testAnUnreadReplicaKeepsWhatShows() async throws {
        let model = OccasionsModel()
        await model.load(replica: try seasons(), profileId: 1, now: at("2026-12-24T15:00:00Z"), timeZone: utc)
        await model.load(replica: Replica(directory: Fixtures.replicas), profileId: 1)
        XCTAssertTrue(model.answered)
        XCTAssertEqual(model.shelves.map(\.name), ["Christmas", "New Year"])
    }

    func testAWindowCanCrossTheYearAndLeapDayNeedsALeapYear() {
        let day = { (text: String) in self.at(text + "T00:00:00Z") }
        let leap = { (text: String) in
            OccasionsModel.window(on: day(text), before: 0, after: 0) {
                OccasionsModel.anchor(in: $0, holiday: nil, month: 2, day: 29)
            }?.distance
        }
        XCTAssertEqual(leap("2028-02-29"), 0)
        XCTAssertNil(leap("2027-03-01"), "no Feb 29 in 2027")
        let newYear = OccasionsModel.window(on: day("2026-12-28"), before: 10, after: 2) {
            OccasionsModel.anchor(in: $0, holiday: [day("2026-01-01"), day("2027-01-01")], month: 0, day: 0)
        }
        XCTAssertEqual(newYear?.anchor, day("2027-01-01"))
        XCTAssertEqual(newYear?.distance, 4)
        XCTAssertNil(
            OccasionsModel.window(on: day("2026-12-28"), before: 10, after: 2) {
                OccasionsModel.anchor(in: $0, holiday: [], month: 0, day: 0)
            }, "a holiday without this year's date")
    }
}

@MainActor
final class OccasionRowTitleTests: XCTestCase {
    func testABlankHeadlineIsNoHeadline() {
        let blank = ActiveOccasion(
            id: OccasionCase.christmas, name: "Christmas", headline: " ", anchorDate: "2026-12-25",
            firstDate: "2026-12-01",
            lastDate: "2026-12-31")
        XCTAssertEqual(blank.rowTitle, "Christmas")
    }
}

final class OccasionMembersTests: OccasionCase {
    private func model(_ replica: Replica, _ profile: UID = 1) -> CatalogModel {
        CatalogModel(client: ServerEndpoint.default.client(token: "t"), replica: replica, profileId: profile)
    }

    func testTheOccasionScreenPagesEveryMemberTheProfileBrowses() async throws {
        let replica = try seasons { db in
            for id in 1000...1200 { try db.item(.n(id), "movie", "Gift \(id)", rating: "R") }
            for id in 1000...1200 {
                try db.execute(
                    sql: "INSERT INTO occasion_item(occasion_id, item_id) VALUES (?, ?)",
                    arguments: [Self.christmas, UID.n(id)])
            }
        }
        let pager = model(replica).occasionMembers(Self.christmas)
        await pager.loadMore()
        XCTAssertEqual(pager.items.count, 200)
        XCTAssertFalse(pager.done)
        await pager.loadAll()
        XCTAssertEqual(pager.items.count, 227)
        XCTAssertEqual(pager.items.first?.id, 127)
        let kid = model(replica, 3).occasionMembers(Self.christmas)
        await kid.loadAll()
        XCTAssertEqual(kid.items.count, 26, "not the R-rated gifts")
    }

    func testATitlesDetailsRowHoldsTheOtherMembersOfEachOccasionItIsIn() async throws {
        let replica = try seasons {
            try $0.execute(
                sql: "INSERT INTO occasion_item(occasion_id, item_id) VALUES (?, ?)", arguments: [UID.n(3), UID.n(125)])
        }
        let rows = await model(replica).occasionRows(
            containing: 300, now: at("2026-12-24T12:00:00Z"), timeZone: utc)
        XCTAssertEqual(rows.map(\.name), ["New Year"])
        XCTAssertEqual(rows.first?.items.map(\.id), [125])
        let none = await model(replica).occasionRows(containing: 200, now: at("2026-12-24T12:00:00Z"), timeZone: utc)
        XCTAssertTrue(none.isEmpty, "Halloween is out of season")
    }
}
