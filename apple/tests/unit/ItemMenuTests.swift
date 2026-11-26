import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

final class ItemMenuActionsTests: XCTestCase {
    func testAnAdultRulesAMovieAndAShowOnly() {
        for kind in [ItemKind.movie, .show] {
            let actions = ItemMenuActions(kind: kind, adult: true, allowListKids: true)
            XCTAssertTrue(actions.kidsRules, "\(kind)")
            XCTAssertTrue(actions.allowList, "\(kind)")
        }
        for kind in [ItemKind.season, .episode] {
            let actions = ItemMenuActions(kind: kind, adult: true, allowListKids: true)
            XCTAssertFalse(actions.kidsRules, "\(kind) follows its show")
            XCTAssertFalse(actions.allowList, "\(kind) follows its show")
        }
    }

    func testTheAllowListNeedsAKidOnOne() {
        let actions = ItemMenuActions(kind: .movie, adult: true, allowListKids: false)
        XCTAssertTrue(actions.kidsRules)
        XCTAssertFalse(actions.allowList)
    }

    func testAnAdultAddsAnyKindAndOnlyAMovieToACollection() {
        XCTAssertEqual(
            [ItemKind.movie, .show, .season, .episode].map {
                ItemMenuActions(kind: $0, adult: true, allowListKids: false).addToCollection
            }, [true, false, false, false])
        XCTAssertTrue(ItemMenuActions(kind: .episode, adult: true, allowListKids: false).addTo)
    }

    func testAKidGetsNoRulesAndNoAdding() {
        for kind in [ItemKind.movie, .show, .season, .episode] {
            let actions = ItemMenuActions(kind: kind, adult: false, allowListKids: true)
            XCTAssertEqual(
                [actions.kidsRules, actions.allowList, actions.addTo, actions.addToCollection],
                [false, false, false, false], "\(kind)")
        }
    }
}

@MainActor
final class AllowListsTests: XCTestCase {
    let kid = Fixtures.decode(Fixtures.kid, as: Account.self)
    var other: Account {
        var other = kid
        other.id = 5
        return other
    }

    func client(_ transport: RoutingTransport) -> Client {
        ServerEndpoint(userInput: "192.168.1.9")!.client(token: "t", transport: transport)
    }

    func testATitleIsHeldByTheKidsWhoseListNamesIt() async {
        let transport = RoutingTransport([
            "GET /profiles/2/allowed-items": (.ok, #"{"itemIds":[30,31]}"#),
            "GET /profiles/5/allowed-items": (.ok, #"{"itemIds":[31]}"#),
        ])
        let lists = AllowLists()
        await lists.load(kids: [kid, other], client: client(transport))
        XCTAssertEqual(lists.kids(holding: 30), [2])
        XCTAssertEqual(lists.kids(holding: 31), [2, 5])
        XCTAssertEqual(lists.kids(holding: 99), [])
        XCTAssertEqual(transport.paths(.get).count, 2, "one read per kid, not one per title")
    }

    func testAKidWhoseListFailsToLoadHoldsNothingAndOthersStay() async {
        let transport = RoutingTransport([
            "GET /profiles/2/allowed-items": (.internalServerError, Fixtures.error("boom")),
            "GET /profiles/5/allowed-items": (.ok, #"{"itemIds":[31]}"#),
        ])
        let lists = AllowLists()
        await lists.load(kids: [kid, other], client: client(transport))
        XCTAssertEqual(lists.kids(holding: 31), [5])
    }

    func testALoadReplacesWhatWasKnown() async {
        let lists = AllowLists()
        lists.set([2], for: 30)
        await lists.load(kids: [], client: client(RoutingTransport()))
        XCTAssertEqual(lists.kids(holding: 30), [])
    }

    func testAllowingAndDisallowingInTheHouseholdKeepsItInStep() async throws {
        let transport = RoutingTransport([
            "POST /auth/sign-in": (.created, Fixtures.signedIn),
            "GET /me": (.ok, Fixtures.me),
            "PUT /profiles/2/allowed-items/31": (.noContent, ""),
            "DELETE /profiles/2/allowed-items/31": (.noContent, ""),
        ])
        let app = AppModel(store: MemoryCredentialStore(), deviceName: "Mac", transport: transport)
        try await app.signIn(server: "rabbit.local", email: "a@example.test", password: "x")
        let household = HouseholdModel(app: app)
        try await household.allow(kid, 31)
        XCTAssertEqual(app.allowLists.kids(holding: 31), [2])
        try await household.disallow(kid, 31)
        XCTAssertEqual(app.allowLists.kids(holding: 31), [])
    }
}
