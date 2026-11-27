import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// Remember profile: a launch continues as the profile last active on this
/// device, instead of Who's watching, for the adult who asked for it here.
@MainActor
final class RememberProfileTests: XCTestCase {
    var store: MemoryCredentialStore!
    var transport: RoutingTransport!

    override func setUp() async throws {
        store = MemoryCredentialStore()
        transport = RoutingTransport([
            "POST /auth/sign-in": (.created, Fixtures.signedIn),
            "GET /me": (.ok, Fixtures.me),
            "POST /me/lock": (.noContent, ""),
            "POST /profiles/\(UID.n(1))/unlock": (.noContent, ""),
            "POST /profiles/\(UID.n(2))/unlock": (.noContent, ""),
        ])
    }

    private func model(remembering: Bool = true) -> AppModel {
        AppModel(
            store: store, deviceName: "Test Mac", rememberProfileByDefault: remembering, transport: transport,
            replicaDirectory: Fixtures.replicas)
    }

    /// Signs in, picks a profile, and returns a fresh model on the same
    /// store, as the next launch would make, with the request log cleared.
    private func lastActive(
        _ id: UID, pin: String? = nil, remembering: Bool = true, _ memory: ((AppModel) -> Void)? = nil
    ) async throws -> AppModel {
        let first = model(remembering: remembering)
        try await first.signIn(server: "rabbit.local", email: "a@example.test", password: "x")
        try await first.choose(try XCTUnwrap(first.profiles.first { $0.id == id }), pin: pin)
        memory?(first)
        transport = RoutingTransport(transport.routes)
        return model(remembering: remembering)
    }

    private func me(locked: Bool = false, active: UID = 1, adult: String = Fixtures.adult) -> String {
        let me = Fixtures.me.replacingOccurrences(
            of: #""activeProfileId":"\#(UID.n(1))""#, with: #""activeProfileId":"\#(active)""#
        )
        .replacingOccurrences(of: Fixtures.adult, with: adult)
        return locked ? String(me.dropLast()) + #","locked":true}"# : me
    }

    func testALaunchContinuesAsTheRememberedProfileWithoutLocking() async throws {
        let next = try await lastActive(1)
        transport.routes["GET /me"] = (.ok, me())
        await next.restore()
        XCTAssertEqual(next.phase, .browsing)
        XCTAssertEqual(next.activeProfile?.id, 1)
        XCTAssertEqual(transport.paths(.post), [])
    }

    func testALaunchUnlocksTheRememberedProfileOnADeviceLeftAtWhoIsWatching() async throws {
        let next = try await lastActive(1)
        transport.routes["GET /me"] = (.ok, me(locked: true))
        await next.restore()
        XCTAssertEqual(next.phase, .browsing)
        XCTAssertEqual(next.activeProfile?.id, 1)
        XCTAssertFalse(next.locked)
        XCTAssertEqual(transport.paths(.post), ["/profiles/\(UID.n(1))/unlock"])
    }

    func testWithRememberOffALaunchLocksAtWhoIsWatching() async throws {
        let next = try await lastActive(1) { $0.profileMemory.remember = false }
        await next.restore()
        XCTAssertEqual(next.phase, .choosingProfile)
        XCTAssertTrue(next.locked)
        XCTAssertNil(next.pinPrompt)
        XCTAssertEqual(transport.paths(.post), ["/me/lock"])
    }

    func testThePlatformDefaultAppliesUntilTheAdultChanges() async throws {
        let next = try await lastActive(1, remembering: false)
        XCTAssertFalse(next.profileMemory.remember)
        await next.restore()
        XCTAssertFalse(next.profileMemory.remember)
        XCTAssertFalse(next.profileMemory.skipPin)
        XCTAssertEqual(next.phase, .choosingProfile)
        next.profileMemory.remember = true
        let after = model(remembering: false)
        await after.restore()
        XCTAssertEqual(after.phase, .browsing)
    }

    func testAPinProfileWithoutSkipPinOpensItsPinAtALockedWhoIsWatching() async throws {
        let next = try await lastActive(2, pin: "1234") { $0.profileMemory.skipPin = false }
        transport.routes["GET /me"] = (.ok, me(active: 2))
        await next.restore()
        XCTAssertEqual(next.phase, .choosingProfile)
        XCTAssertTrue(next.locked)
        XCTAssertEqual(next.pinPrompt?.id, 2)
        XCTAssertEqual(transport.paths(.post), ["/me/lock"])
        try await next.choose(try XCTUnwrap(next.pinPrompt), pin: "1234")
        XCTAssertEqual(next.phase, .browsing)
        XCTAssertNil(next.pinPrompt)
    }

    func testSkipPinContinuesAsAPinProfileTheServerStillHasUnlocked() async throws {
        let next = try await lastActive(2, pin: "1234") { $0.profileMemory.skipPin = true }
        transport.routes["GET /me"] = (.ok, me(active: 2))
        await next.restore()
        XCTAssertEqual(next.phase, .browsing)
        XCTAssertEqual(next.activeProfile?.id, 2)
        XCTAssertEqual(transport.paths(.post), [])
    }

    func testSkipPinStillAsksForThePinOnceTheServerHasLockedTheDevice() async throws {
        let next = try await lastActive(2, pin: "1234") { $0.profileMemory.skipPin = true }
        transport.routes["GET /me"] = (.ok, me(locked: true, active: 2))
        await next.restore()
        XCTAssertEqual(next.phase, .choosingProfile)
        XCTAssertEqual(next.pinPrompt?.id, 2)
        XCTAssertEqual(transport.paths(.post), [])
    }

    func testAProfileThatIsGoneFallsBackToWhoIsWatching() async throws {
        let next = try await lastActive(2, pin: "1234")
        transport.routes["GET /me"] = (.ok, me().replacingOccurrences(of: ",\(Fixtures.kid)", with: ""))
        await next.restore()
        XCTAssertEqual(next.phase, .choosingProfile)
        XCTAssertNil(next.pinPrompt)
        XCTAssertEqual(transport.paths(.post), ["/me/lock"])
    }

    func testAnUnlockTheServerRefusesFallsBackToWhoIsWatching() async throws {
        let next = try await lastActive(1)
        transport.routes["GET /me"] = (.ok, me(locked: true, active: 2))
        transport.routes["POST /profiles/\(UID.n(1))/unlock"] = (.forbidden, Fixtures.error("forbidden"))
        await next.restore()
        XCTAssertEqual(next.phase, .choosingProfile)
        XCTAssertNil(next.activeProfile)
        XCTAssertTrue(next.locked)
    }

    func testSigningInAndSwitchingProfileStillShowWhoIsWatching() async throws {
        let next = try await lastActive(1)
        try await next.signIn(server: "rabbit.local", email: "a@example.test", password: "x")
        XCTAssertEqual(next.phase, .choosingProfile)
        try await next.choose(try XCTUnwrap(next.profiles.first))
        await next.switchProfile()
        XCTAssertEqual(next.phase, .choosingProfile)
        XCTAssertNil(next.pinPrompt)
        XCTAssertEqual(
            transport.paths(.post), ["/auth/sign-in", "/me/lock", "/profiles/\(UID.n(1))/unlock", "/me/lock"])
    }

    func testEachSignedInAdultHasTheirOwnSettings() async throws {
        let next = try await lastActive(1) {
            $0.profileMemory.remember = false
            $0.profileMemory.skipPin = false
        }
        let other = Fixtures.account(3, "Sam")
        transport.routes["GET /me"] = (
            .ok,
            me(active: 3).replacingOccurrences(of: #""account":\#(Fixtures.adult)"#, with: #""account":\#(other)"#)
        )
        await next.restore()
        XCTAssertTrue(next.profileMemory.remember)
        XCTAssertTrue(next.profileMemory.skipPin)
        XCTAssertNil(next.profileMemory.lastProfileId)
    }
}
