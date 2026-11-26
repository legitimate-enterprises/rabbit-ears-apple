import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// Which household a device signed in by an adult of several is in.
@MainActor
final class HouseholdChoiceTests: XCTestCase {
    var transport: RoutingTransport!
    var app: AppModel!

    /// A sign-in answer naming the adult's households, their own first.
    static func signedIn(_ households: [(Int64, String)]) -> String {
        let list = households.map { #"{"id":\#($0.0),"name":"\#($0.1)"}"# }.joined(separator: ",")
        return #"{"token":"tok-1","me":\#(Fixtures.me),"households":[\#(list)]}"#
    }

    override func setUp() async throws {
        transport = RoutingTransport([
            "POST /auth/sign-in": (.created, Self.signedIn([(1, "Avery"), (2, "Mark")])),
            "POST /me/lock": (.noContent, ""),
            "PUT /me/household": (.noContent, ""),
            "GET /me": (.ok, Fixtures.me),
        ])
        app = AppModel(store: MemoryCredentialStore(), deviceName: "Mac", transport: transport)
    }

    private func signIn() async throws {
        try await app.signIn(server: "rabbit.local", email: "a@example.test", password: "x")
    }

    func testASignInInSeveralHouseholdsAsksWhichBeforeWhoIsWatching() async throws {
        try await signIn()
        XCTAssertEqual(app.phase, .choosingHousehold)
        XCTAssertEqual(app.households.map(\.name), ["Avery", "Mark"])
        XCTAssertFalse(transport.paths(.post).contains("/me/lock"), "moving needs the device unlocked")
        try await app.chooseHousehold(app.households[0])
        XCTAssertTrue(transport.paths(.put).isEmpty, "the device starts in the adult's own")
        XCTAssertEqual(app.phase, .choosingProfile)
        XCTAssertTrue(app.households.isEmpty, "asked once")
        XCTAssertEqual(transport.paths(.post).last, "/me/lock")
    }

    func testChoosingAnotherMovesTheDeviceThere() async throws {
        let moved = Fixtures.me.replacingOccurrences(
            of: #""name":"Avery","adultId":1"#, with: #""name":"Mark","adultId":7"#)
        transport.routes["GET /me"] = (.ok, moved)
        try await signIn()
        try await app.chooseHousehold(app.households[1])
        XCTAssertEqual(transport.json(.put, "/me/household")?["householdId"] as? Int, 2)
        XCTAssertEqual(app.householdName, "Mark")
        XCTAssertEqual(app.phase, .choosingProfile)
        XCTAssertEqual(transport.paths(.post).last, "/me/lock")
    }

    func testAFailedMoveStaysOnTheChoice() async throws {
        transport.routes["PUT /me/household"] = (.notFound, Fixtures.error("not_found", "No such household."))
        try await signIn()
        do {
            try await app.chooseHousehold(app.households[1])
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? AppError, .server("No such household."))
        }
        XCTAssertEqual(app.phase, .choosingHousehold)
    }

    func testJoiningAsksToo() async throws {
        transport.routes["POST /join/7KQ4-MNP2"] = (.created, Self.signedIn([(1, "Avery"), (2, "Mark")]))
        try await app.acceptJoin(server: "rabbit.local", code: "7KQ4-MNP2", name: "Avery", password: "long password")
        XCTAssertEqual(app.phase, .choosingHousehold)
    }

    func testOneHouseholdIsNotAsked() async throws {
        transport.routes["POST /auth/sign-in"] = (.created, Self.signedIn([(1, "Avery")]))
        try await signIn()
        XCTAssertEqual(app.phase, .choosingProfile)
    }

    func testATVSignedInByLinkCodeIsNotAsked() async throws {
        let link = DeviceLink(id: 5, code: "7KQ4MN", link: "", expiresAt: Date(), pollToken: "p")
        let signIn = Self.signedIn([(1, "Avery"), (2, "Mark")])
        let answer = #"{"status":"approved","expiresAt":"2026-01-01T00:10:00Z","signIn":\#(signIn)}"#
        transport.routes["GET /device-links/5"] = (.ok, answer)
        let status = try await app.pollLink(link, server: XCTUnwrap(ServerEndpoint(userInput: "rabbit.local")))
        XCTAssertEqual(status, .approved)
        XCTAssertEqual(app.phase, .choosingProfile)
        XCTAssertTrue(app.households.isEmpty)
    }
}
