import Foundation
import GRDB
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// Allow lists, kids' content and profile settings, read from the replica
/// and written through the queue, offline as online.
@MainActor
final class HouseholdActionsTests: XCTestCase {
    var app: SyncedApp!
    let robin = Fixtures.decode(Fixtures.kid, as: Account.self)
    var bea: Account {
        var bea = robin
        bea.id = 4
        bea.name = "Bea"
        return bea
    }

    override func setUp() async throws {
        app = try SyncedApp { db in
            try db.member(1, "Avery")
            try db.member(2, "Robin", kind: "kid", filter: "allow_list", pin: true)
            try db.member(4, "Bea", kind: "kid", filter: "allow_list")
            try db.member(5, "Cal", kind: "kid")
            try db.member(6, "Dee", kind: "kid", filter: "allow_list", household: 8)
            try db.item(30, "movie", "Toy Story", rating: "G")
            try db.item(31, "movie", "Matrix", rating: "R")
            try db.item(33, "channel", "Kids Channel")
            try db.item(34, "movie", "Up", rating: "PG")
            try db.item(35, "movie", "Animatrix", rating: "PG-13")
            try db.item(36, "show", "Mathletes", rating: "TV-14")
            try db.item(37, "season", "Mathletes", parent: 36, season: 1)
            for (kid, item): (UID, UID) in [(2, 34), (2, 33), (2, 30), (4, 30), (5, 30), (6, 30)] {
                try db.allow(item, for: kid)
            }
            try db.item(20, "movie", "Dune", rating: "PG-13")
            try db.item(21, "show", "Bluey", rating: "TV-Y", kids: false)
            try db.item(5, "channel", "Crafts")
        }
        app.routes.routes["POST /profiles/\(UID.n(1))/unlock"] = (.noContent, "")
    }

    override func tearDown() { app.remove() }

    func testAKidsAllowListIsItsCatalogTitlesInIdOrder() async throws {
        _ = try await app.synced()
        let allowed = try await HouseholdModel(app: app.model).allowed(robin)
        XCTAssertEqual(allowed.map(\.id), [30, 34], "the channel is not a title getItem finds")
        XCTAssertEqual(allowed.first?.kidsContent, true)
    }

    func testFindingTitlesIsListItemsByTitleKeepingMoviesAndShows() async throws {
        _ = try await app.synced()
        let household = HouseholdModel(app: app.model)
        let found = try await household.findTitles("MAT")
        XCTAssertEqual(found.map(\.id), [35, 36, 31], "by title, not starts-with first")
        let toy = try await household.findTitles("toy")
        XCTAssertEqual(toy.map(\.id), [30])
        XCTAssertFalse(app.routes.paths(.get).contains("/items"))
    }

    func testAllowedForNamesTheHouseholdsKidsOnAListThatHoldsIt() async throws {
        _ = try await app.synced()
        let household = HouseholdModel(app: app.model)
        let holders = try await household.allowedFor(30)
        XCTAssertEqual(holders, [2, 4])
        let none = try await household.allowedFor(99)
        XCTAssertEqual(none, [])
    }

    func testTheMenusListsAreEachKidsOwnFromTheReplica() async throws {
        let sync = try await app.synced()
        let lists = app.model.allowLists
        lists.set([5], for: 99)
        await lists.load(kids: [robin, bea], replica: sync.replica)
        XCTAssertEqual(lists.kids(holding: 30), [2, 4])
        XCTAssertEqual(lists.kids(holding: 34), [2])
        XCTAssertEqual(lists.kids(holding: 99), [], "a load replaces what was known")
    }

    func testAllowingAndDisallowingWriteTheReplicaAndQueueTheCallsOfflineToo() async throws {
        let sync = try await app.synced()
        let household = HouseholdModel(app: app.model)
        app.offline()
        try await household.allow(robin, 31)
        try await household.disallow(robin, 30)
        XCTAssertEqual(app.model.allowLists.kids(holding: 31), [2])
        XCTAssertEqual(app.model.allowLists.kids(holding: 30), [])
        let held: [UID] = try await sync.replica.read {
            try UID.fetchAll(
                $0, sql: "SELECT item_id FROM account_allow WHERE account_id = \(sqlID(2)) ORDER BY item_id")
        }
        XCTAssertEqual(held, [31, 33, 34])
        let queued = try await app.queued()
        XCTAssertEqual(
            queued,
            [
                "allowItem PUT /profiles/\(UID.n(2))/allowed-items/\(UID.n(31))",
                "disallowItem DELETE /profiles/\(UID.n(2))/allowed-items/\(UID.n(30))",
            ])
        let touched = try await app.touched()
        XCTAssertEqual(
            touched, ["account_allow \(UID.n(2))/\(UID.n(31))", "account_allow \(UID.n(2))/\(UID.n(30))"],
            "id key parts are their lowercase strings")
        app.routes.failure = nil
        let flushed = await sync.queue.flush()
        XCTAssertEqual(flushed, .done)
    }

    func testPreferencesAreSavedHereAtOnceAndTheProfilesWearThem() async throws {
        let sync = try await app.synced()
        let avery = try XCTUnwrap(app.model.profiles.first)
        try await app.model.choose(avery)
        app.offline()
        try await app.model.savePreferences(for: avery, color: "#5b4a8a", hideKidsContent: true)
        XCTAssertEqual(app.model.activeProfile?.color, "#5B4A8A")
        XCTAssertEqual(app.model.activeProfile?.hideKidsContent, true)
        let color: String? = try await app.value("SELECT color FROM account WHERE id = \(sqlID(1))")
        let card: String? = try await app.value("SELECT color FROM account_card WHERE id = \(sqlID(1))")
        let hiding: Bool? = try await app.value("SELECT hide_kids_content FROM account WHERE id = \(sqlID(1))")
        XCTAssertEqual([color, card], ["#5B4A8A", "#5B4A8A"])
        XCTAssertEqual(hiding, true)

        try await app.model.savePreferences(for: robin, color: nil, hideKidsContent: nil, autoplay: false)
        let kid = try XCTUnwrap(app.model.profiles.first { $0.id == 2 })
        XCTAssertEqual(kid.autoplay, false)
        XCTAssertEqual(kid.color, "#6B3A2E", "no color of its own shows the palette's for its id")
        XCTAssertNil(kid.hideKidsContent, "a kid has no Hide")
        let stopped: Bool? = try await app.value("SELECT no_autoplay FROM account WHERE id = \(sqlID(2))")
        XCTAssertEqual(stopped, true)
        let queued = try await app.queued()
        XCTAssertEqual(
            queued,
            [
                "setProfilePreferences PUT /profiles/\(UID.n(1))/preferences",
                "setProfilePreferences PUT /profiles/\(UID.n(2))/preferences",
            ])
        let touched = try await app.touched()
        XCTAssertEqual(touched, ["account \(UID.n(1))", "account_card \(UID.n(1))", "account \(UID.n(2))"])

        app.routes.failure = nil
        _ = await sync.queue.flush()
        let bodies = app.sentBodies()
        XCTAssertEqual(bodies.first?["color"] as? String, "#5B4A8A")
        XCTAssertEqual(bodies.first?["hideKidsContent"] as? Bool, true)
        XCTAssertNil(bodies.first?["autoplay"])
        XCTAssertEqual(bodies.last?["autoplay"] as? Bool, false)
        XCTAssertNil(bodies.last?["color"])
    }

    func testKidsContentIsTheItemsOwnRowNullWhenCleared() async throws {
        let queue = try await app.synced().queue
        app.offline()
        try await queue.setKidsContent(true, for: 20, as: 1)
        try await queue.setKidsContent(nil, for: 21, as: 1)
        try await queue.setYouTubeChannelForKids(true, channel: 5, as: 1)
        let dune: Bool? = try await app.value("SELECT kids_content FROM item WHERE id = \(sqlID(20))")
        let bluey: Bool? = try await app.value("SELECT kids_content FROM item WHERE id = \(sqlID(21))")
        let crafts: Bool? = try await app.value("SELECT kids_content FROM item WHERE id = \(sqlID(5))")
        XCTAssertEqual(dune, true)
        XCTAssertNil(bluey, "the rating decides again")
        XCTAssertEqual(crafts, true)
        let queued = try await app.queued()
        XCTAssertEqual(
            queued,
            [
                "setKidsContent PUT /items/\(UID.n(20))/kids-content",
                "clearKidsContent DELETE /items/\(UID.n(21))/kids-content",
                "setYouTubeChannelForKids PUT /youtube/channels/\(UID.n(5))/for-kids",
            ])
        let touched = try await app.touched()
        XCTAssertEqual(touched, ["item \(UID.n(20))", "item \(UID.n(21))", "item \(UID.n(5))"])
    }

    /// A whole action's items and six more, uid.N(100) on.
    static let ids = (100..<(106 + ActionQueue.itemsLimit)).map(UID.n)

    func testASelectionsKidsContentIsSentInBatchesOfTheItemsLimit() async throws {
        app.remove()
        app = try SyncedApp { db in
            for id in Self.ids { try db.item(id, "movie", "T\(id)", rating: "G") }
        }
        let sync = try await app.synced()
        app.offline()
        try await sync.queue.setKidsContents(false, for: Self.ids, as: 1)
        let marked: Int? = try await app.value("SELECT count(*) FROM item WHERE kids_content = 0")
        XCTAssertEqual(marked, ActionQueue.itemsLimit + 6)
        let queued = try await app.queued()
        XCTAssertEqual(queued, Array(repeating: "setKidsContents PUT /items/kids-content/batch", count: 2))
        app.routes.failure = nil
        _ = await sync.queue.flush()
        let ids = app.sentBodies().map { ($0["itemIds"] as? [String]) ?? [] }
        let sent = Self.ids.map(\.description)
        XCTAssertEqual(ids, [Array(sent[..<ActionQueue.itemsLimit]), Array(sent[ActionQueue.itemsLimit...])])
        XCTAssertEqual(app.sentBodies().first?["kidsContent"] as? Bool, false)
    }
}
