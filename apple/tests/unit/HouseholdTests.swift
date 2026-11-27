import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

private func pending(_ id: Int64, _ name: String, expires: String? = nil) -> String {
    let invite = expires.map { #","inviteExpiresAt":"\#($0)""# } ?? ""
    return Fixtures.account(id, name).replacingOccurrences(of: #""pending":false"#, with: #""pending":true\#(invite)"#)
}

final class MemberActionsTests: XCTestCase {
    let owner = Fixtures.decode(Fixtures.adult, as: Account.self)
    let other = Fixtures.decode(Fixtures.account(4, "Bea"), as: Account.self)
    let kid = Fixtures.decode(Fixtures.kid, as: Account.self)
    let invited = Fixtures.decode(pending(3, "Cy"), as: Account.self)

    func testTheOwnerManagesEveryoneButThemselves() {
        XCTAssertEqual(MemberActions.allowed(for: owner, active: owner, ownerId: 1), [.setPin, .share])
        XCTAssertEqual(
            MemberActions.allowed(for: kid, active: owner, ownerId: 1),
            [.editKid, .setPin, .share, .remove, .makeAdult])
        XCTAssertEqual(MemberActions.allowed(for: other, active: owner, ownerId: 1), [.share, .remove])
        XCTAssertEqual(MemberActions.allowed(for: invited, active: owner, ownerId: 1), [.resendCode, .remove])
    }

    func testAnotherAdultLooksAfterKidsAndTheirOwnPinOnly() {
        XCTAssertEqual(
            MemberActions.allowed(for: kid, active: other, ownerId: 1), [.editKid, .setPin, .share, .remove])
        XCTAssertEqual(MemberActions.allowed(for: other, active: other, ownerId: 1), [.setPin, .share])
        XCTAssertEqual(MemberActions.allowed(for: owner, active: other, ownerId: 1), [.share])
    }

    func testMemberLinesSayWhoEachIs() {
        XCTAssertEqual(Format.member(owner, ownerId: 1), "Owner")
        XCTAssertEqual(Format.member(other, ownerId: 1), "Adult")
        XCTAssertEqual(Format.member(invited, ownerId: 1), "Awaiting sign-in · code expired")
        let expiring = Fixtures.decode(pending(3, "Cy", expires: "2026-01-08T12:00:00.5Z"), as: Account.self)
        XCTAssertTrue(Format.member(expiring, ownerId: 1).hasPrefix("Awaiting sign-in · code expires "))
        var ceilings = kid
        ceilings.movieCeiling = .pg
        ceilings.tvCeiling = .tvY7
        XCTAssertEqual(Format.member(ceilings, ownerId: 1), "Kid · movies up to PG · TV up to TV-Y7")
        ceilings.filterMode = .allowList
        XCTAssertEqual(Format.member(ceilings, ownerId: 1), "Kid · only titles you choose")
    }

    func testAKidMayDoNothing() {
        XCTAssertEqual(MemberActions.allowed(for: kid, active: kid, ownerId: 1), [])
        XCTAssertEqual(MemberActions.allowed(for: owner, active: nil, ownerId: 1), [])
    }
}

@MainActor
final class HouseholdModelTests: XCTestCase {
    var transport: RoutingTransport!
    var app: AppModel!
    var model: HouseholdModel!

    let invite =
        #"{"account":\#(pending(2, "Robin")),"joinCode":{"id":5,"code":"7KQ4-MNP2","link":"/join/7KQ4-MNP2","#
        + #""accountId":2,"expiresAt":"2026-01-08T00:00:00.123456789Z","createdAt":"2026-01-01T00:00:00.5Z"}}"#

    override func setUp() async throws {
        transport = RoutingTransport([
            "POST /auth/sign-in": (.created, Fixtures.signedIn),
            "GET /me": (.ok, Fixtures.me),
            "GET /profiles": (
                .ok,
                Fixtures.page([Fixtures.adult, Fixtures.kid, pending(3, "Cy", expires: "2026-01-08T00:00:00.25Z")])
            ),
            "GET /household/offers": (.ok, #"{"incoming":[],"outgoing":[]}"#),
        ])
        app = AppModel(
            store: MemoryCredentialStore(), deviceName: "Mac", transport: transport, replicaDirectory: Fixtures.replicas
        )
        try await app.signIn(server: "rabbit.local", email: "a@example.test", password: "x")
        model = HouseholdModel(app: app)
    }

    func testListsMembersWithPendingExpiry() async throws {
        await model.load()
        XCTAssertNil(model.error)
        XCTAssertEqual(model.members.map(\.name), ["Avery", "Robin", "Cy"])
        let expiry = try XCTUnwrap(model.members.last?.inviteExpiresAt)
        XCTAssertEqual(expiry.timeIntervalSince1970, 1_767_830_400.25, accuracy: 0.001)
        XCTAssertEqual(model.actions(for: model.members[2]), [.resendCode, .remove])
    }

    func testEditingAKidReplacesItAndChangesThePinOnlyWhenAsked() async throws {
        transport.routes["PUT /profiles/2"] = (.ok, Fixtures.kid)
        transport.routes["DELETE /profiles/2/pin"] = (.noContent, "")
        transport.routes["PUT /profiles/2/pin"] = (.noContent, "")
        let born = Fixtures.kid.replacingOccurrences(
            of: #""filterMode""#, with: #""birthday":"2017-08-19","filterMode""#)
        let kid = Fixtures.decode(born, as: Account.self)
        var form = AddKidForm(editing: kid)
        XCTAssertEqual(form.birthdayString, "2017-08-19")
        XCTAssertEqual(form.submitTitle, "Save")
        XCTAssertEqual(form.pinChange, .keep)
        XCTAssertTrue(form.errors.isEmpty)
        form.name = "Robbie"
        try await model.saveKid(kid, form)
        XCTAssertEqual(transport.json(.put, "/profiles/2")?["name"] as? String, "Robbie")
        XCTAssertTrue(transport.paths(.put).allSatisfy { $0 != "/profiles/2/pin" })
        form.requirePin = false
        try await model.saveKid(kid, form)
        XCTAssertEqual(transport.paths(.delete), ["/profiles/2/pin"])
        form.requirePin = true
        form.pin = "2468"
        form.pinConfirmation = "2468"
        try await model.saveKid(kid, form)
        XCTAssertEqual(transport.json(.put, "/profiles/2/pin")?["pin"] as? String, "2468")
        XCTAssertEqual(transport.paths(.get).filter { $0 == "/profiles" }.count, 3)
    }

    func testResendAndChangeToAdultHandBackTheCode() async throws {
        let cy = Fixtures.decode(pending(3, "Cy"), as: Account.self)
        let kid = Fixtures.decode(Fixtures.kid, as: Account.self)
        transport.routes["POST /profiles/3/join-code"] = (.created, invite)
        transport.routes["POST /profiles/2/make-adult"] = (.created, invite)
        let resent = try await model.resendCode(cy)
        XCTAssertEqual(resent.url.absoluteString, "http://rabbit.local:8477/join/7KQ4-MNP2")
        let made = try await model.makeAdult(kid, email: "robin@example.test")
        XCTAssertEqual(made.code, "7KQ4-MNP2")
        XCTAssertEqual(transport.json(.post, "/profiles/2/make-adult")?["email"] as? String, "robin@example.test")
        transport.routes["POST /profiles/2/make-adult"] = (.conflict, Fixtures.error("conflict"))
        do {
            _ = try await model.makeAdult(kid, email: "taken@example.test")
            XCTFail("expected emailTaken")
        } catch {
            XCTAssertEqual(error as? AppError, .emailTaken)
        }
    }

    func testRemoveRefreshesWhoIsWatching() async throws {
        let bea = Fixtures.decode(Fixtures.account(4, "Bea"), as: Account.self)
        transport.routes["DELETE /profiles/4"] = (.noContent, "")
        try await model.remove(bea)
        XCTAssertEqual(transport.paths(.delete), ["/profiles/4"])
        XCTAssertEqual(transport.paths(.get).filter { $0 == "/me" }.count, 1)
        transport.routes["DELETE /profiles/4"] = (.conflict, Fixtures.error("conflict", "Last admin."))
        do {
            try await model.remove(bea)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? AppError, .server("Last admin."))
        }
    }

    func testChoosingAKidTakesAwayHouseholdPowers() async throws {
        transport.routes["POST /profiles/2/unlock"] = (.noContent, "")
        XCTAssertTrue(app.canManageHousehold)
        try await app.choose(try XCTUnwrap(app.profiles.last), pin: "1234")
        XCTAssertFalse(app.canManageHousehold)
        XCTAssertFalse(app.isOwner)
        XCTAssertEqual(model.actions(for: Fixtures.decode(Fixtures.kid, as: Account.self)), [])
    }

    func testAKidsColorIsSavedWithTheKid() async throws {
        transport.routes["PUT /profiles/2"] = (.ok, Fixtures.kid)
        let colored = Fixtures.kid.replacingOccurrences(
            of: #""filterMode""#, with: ##""color":"#3C4170","filterMode""##)
        let kid = Fixtures.decode(colored, as: Account.self)
        var form = AddKidForm(editing: kid)
        XCTAssertEqual(form.color, "#3C4170")
        form.color = "#6B2E5A"
        try await model.saveKid(kid, form)
        XCTAssertEqual(transport.json(.put, "/profiles/2")?["color"] as? String, "#6B2E5A")
    }

    func testAProfileWearsTheServersColor() {
        let colored = Fixtures.kid.replacingOccurrences(
            of: #""filterMode""#, with: ##""color":"#2E6B5B","filterMode""##)
        XCTAssertEqual(Fixtures.decode(colored, as: Account.self).rgb, 0x2E6B5B)
        XCTAssertEqual(Fixtures.decode(Fixtures.kid, as: Account.self).rgb, 0x3C4170, "none wears the first")
        XCTAssertEqual(
            ProfilePalette.colors,
            ["#3C4170", "#2E6B5B", "#6B3A2E", "#5B4A8A", "#8A5A2B", "#2E5B8A", "#6B2E5A", "#4A6B2E"])
        XCTAssertEqual(ProfilePalette.placeholder(9), 0x2E6B5B)
        XCTAssertNil(ProfilePalette.rgb("blue"))
    }
}
