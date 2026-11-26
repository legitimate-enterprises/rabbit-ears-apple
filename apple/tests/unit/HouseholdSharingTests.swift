import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

extension Fixtures {
    /// An account in `households` households, `present` as an adult only visiting.
    static func shared(_ json: String, households: Int = 2, present: Bool = false) -> String {
        json.replacingOccurrences(
            of: #""pending":false"#, with: #""pending":false,"households":\#(households),"present":\#(present)"#)
    }

    /// An offer of the kid `profileId`, `name`.
    static func offer(_ id: Int64, of profileId: Int64, _ name: String, from: String, to: String) -> String {
        #"{"id":\#(id),"profileId":\#(profileId),"profileName":"\#(name)","profileKind":"kid","#
            + #""householdId":1,"householdName":"Avery","fromProfileId":1,"fromName":"\#(from)","#
            + #""toProfileId":7,"toName":"\#(to)","createdAt":"2026-01-01T00:00:00Z"}"#
    }
}

final class SharedMemberTests: XCTestCase {
    let owner = Fixtures.decode(Fixtures.adult, as: Account.self)
    let other = Fixtures.decode(Fixtures.account(4, "Bea"), as: Account.self)
    let kid = Fixtures.decode(Fixtures.shared(Fixtures.kid), as: Account.self)
    let visitor = Fixtures.decode(Fixtures.shared(Fixtures.account(5, "Jo"), present: true), as: Account.self)

    func testEveryKidAndJoinedAdultOfTheHouseholdMayBeShared() {
        XCTAssertTrue(MemberActions.allowed(for: kid, active: other, ownerId: 1).contains(.share))
        XCTAssertTrue(MemberActions.allowed(for: owner, active: owner, ownerId: 1).contains(.share))
        XCTAssertTrue(MemberActions.allowed(for: other, active: owner, ownerId: 1).contains(.share))
        XCTAssertEqual(MemberActions.allowed(for: owner, active: other, ownerId: 1), [.share])
        let invited = Fixtures.decode(
            Fixtures.account(3, "Cy").replacingOccurrences(of: #""pending":false"#, with: #""pending":true"#),
            as: Account.self)
        XCTAssertFalse(MemberActions.allowed(for: invited, active: owner, ownerId: 1).contains(.share))
    }

    func testAVisitingAdultMayOnlyBeRemovedByAnyAdultOfTheHousehold() {
        XCTAssertEqual(MemberActions.allowed(for: visitor, active: owner, ownerId: 1), [.remove])
        XCTAssertEqual(MemberActions.allowed(for: visitor, active: other, ownerId: 1), [.remove])
    }

    func testASharedProfileSaysHowManyHouseholdsItIsIn() {
        XCTAssertEqual(Format.shared(kid), "In 2 households")
        XCTAssertEqual(Format.shared(Fixtures.decode(Fixtures.shared(Fixtures.kid, households: 3))), "In 3 households")
        XCTAssertEqual(Format.member(visitor, ownerId: 1), "Adult")
        XCTAssertEqual(Format.shared(visitor), "Visiting from another household")
        XCTAssertNil(Format.shared(owner), "absent, as from an older server, is one household")
        XCTAssertNil(Format.shared(Fixtures.decode(Fixtures.shared(Fixtures.adult, households: 1))))
    }

    func testRemovingASharedProfileOnlyTakesItOutOfThisHousehold() {
        XCTAssertEqual(Removal.title(kid), "Remove from this household…")
        XCTAssertEqual(Removal.question(kid), "Remove Robin from this household?")
        XCTAssertEqual(Removal.message(kid), "Robin stays in their other household, and nothing of theirs is deleted.")
        XCTAssertEqual(Removal.title(visitor), "Remove from this household…")
        let three = Fixtures.decode(Fixtures.shared(Fixtures.kid, households: 3), as: Account.self)
        XCTAssertEqual(
            Removal.message(three), "Robin stays in their other households, and nothing of theirs is deleted.")
        let alone = Fixtures.decode(Fixtures.kid, as: Account.self)
        XCTAssertEqual(Removal.title(alone), "Remove…")
        XCTAssertEqual(Removal.question(alone), "Remove Robin?")
        XCTAssertEqual(Removal.message(alone), "Their account and watch history are deleted.")
        XCTAssertEqual(Removal.message(other), "Their devices are signed out.")
    }

    func testAnOfferSaysWhoOffersWhom() {
        let offer = Fixtures.decode(
            Fixtures.offer(3, of: 2, "Jax", from: "Heidi", to: "Avery"), as: ProfileOffer.self)
        XCTAssertEqual(Format.offer(offer, incoming: true), "Kid · Heidi offers to share Jax with your household")
        XCTAssertEqual(Format.offer(offer, incoming: false), "Kid · Offered to Avery, waiting")
    }
}

@MainActor
final class HouseholdSharingTests: XCTestCase {
    var transport: RoutingTransport!
    var app: AppModel!
    var model: HouseholdModel!
    let incoming = Fixtures.offer(3, of: 6, "Jax", from: "Heidi", to: "Avery")
    let outgoing = Fixtures.offer(4, of: 2, "Robin", from: "Avery", to: "Heidi")

    override func setUp() async throws {
        transport = RoutingTransport([
            "POST /auth/sign-in": (.created, Fixtures.signedIn),
            "GET /me": (.ok, Fixtures.me),
            "GET /profiles": (.ok, Fixtures.page([Fixtures.adult, Fixtures.shared(Fixtures.kid)])),
            "GET /household/offers": (.ok, #"{"incoming":[\#(incoming)],"outgoing":[\#(outgoing)]}"#),
        ])
        app = AppModel(store: MemoryCredentialStore(), deviceName: "Mac", transport: transport)
        try await app.signIn(server: "rabbit.local", email: "a@example.test", password: "x")
        model = HouseholdModel(app: app)
    }

    func testLoadingReadsTheOffersBesideTheMembers() async {
        await model.load()
        XCTAssertNil(model.error)
        XCTAssertEqual(model.offers.incoming.map(\.id), [3])
        XCTAssertEqual(model.offers.outgoing.map(\.id), [4])
        XCTAssertTrue(model.anyShared)
        XCTAssertFalse(model.visiting)
    }

    func testAcceptingOrDecliningAnOfferReloadsTheHouseholdAndWhoIsWatching() async throws {
        transport.routes["POST /household/offers/3/accept"] = (.noContent, "")
        transport.routes["DELETE /household/offers/4"] = (.noContent, "")
        await model.load()
        try await model.accept(model.offers.incoming[0])
        try await model.cancel(model.offers.outgoing[0])
        XCTAssertEqual(transport.paths(.post).last, "/household/offers/3/accept")
        XCTAssertEqual(transport.paths(.delete), ["/household/offers/4"])
        XCTAssertEqual(transport.paths(.get).filter { $0 == "/household/offers" }.count, 3)
        XCTAssertEqual(transport.paths(.get).filter { $0 == "/me" }.count, 2)
    }

    func testOfferingAProfileListsConnectedAdultsAndSendsTheOffer() async throws {
        transport.routes["GET /household/linked-adults"] = (.ok, Fixtures.page([Fixtures.account(7, "Heidi")]))
        transport.routes["POST /household/offers"] = (.created, outgoing)
        let robin = Fixtures.decode(Fixtures.kid, as: Account.self)
        let adults = try await model.connectedAdults()
        XCTAssertEqual(adults.map(\.name), ["Heidi"])
        try await model.offer(robin, to: adults[0])
        let sent = transport.json(.post, "/household/offers")
        XCTAssertEqual(sent?["profileId"] as? Int, 2)
        XCTAssertEqual(sent?["toProfileId"] as? Int, 7)
        transport.routes["POST /household/offers"] = (.conflict, Fixtures.error("conflict", "Offered already."))
        do {
            try await model.offer(robin, to: adults[0])
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? AppError, .server("Offered already."))
        }
    }

    func testAVisitingAdultManagesNothing() async throws {
        let jo = Fixtures.shared(Fixtures.account(1, "Jo"), present: true)
        let visiting = Fixtures.me.replacingOccurrences(
            of: #""account":\#(Fixtures.adult)"#, with: #""account":\#(jo)"#
        )
        .replacingOccurrences(of: #""profiles":[\#(Fixtures.adult),"#, with: #""profiles":[\#(jo),"#)
        transport.routes["GET /me"] = (.ok, visiting)
        await app.reload()
        XCTAssertTrue(model.visiting)
        XCTAssertFalse(app.canManageHousehold)
        XCTAssertEqual(model.actions(for: Fixtures.decode(Fixtures.kid, as: Account.self)), [])
    }

    func testLeavingOnTheVisitorsOwnDeviceSignsItOut() async throws {
        transport.routes["DELETE /profiles/1"] = (.noContent, "")
        try await model.leave()
        XCTAssertEqual(transport.paths(.delete), ["/profiles/1"])
        XCTAssertEqual(app.phase, .signedOut, "the server signs the visitor's own devices there out")
    }

    func testLeavingOnAnotherAdultsDeviceGoesBackToWhoIsWatching() async throws {
        transport.routes["POST /profiles/5/unlock"] = (.noContent, "")
        transport.routes["DELETE /profiles/5"] = (.noContent, "")
        transport.routes["POST /me/lock"] = (.noContent, "")
        let jo = Fixtures.shared(Fixtures.account(5, "Jo"), present: true)
        transport.routes["GET /me"] = (
            .ok, Fixtures.me.replacingOccurrences(of: #"\#(Fixtures.kid)]"#, with: #"\#(Fixtures.kid),\#(jo)]"#)
        )
        await app.reload()
        try await app.choose(Fixtures.decode(jo, as: Account.self))
        try await model.leave()
        XCTAssertEqual(transport.paths(.delete), ["/profiles/5"])
        XCTAssertEqual(app.phase, .choosingProfile)
        XCTAssertEqual(transport.paths(.post).last, "/me/lock")
    }
}
