import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// Who's watching holds the device locked on the server until a profile is picked.
@MainActor
final class DeviceLockTests: XCTestCase {
    var store: MemoryCredentialStore!
    var transport: RoutingTransport!
    var model: AppModel!

    override func setUp() async throws {
        store = MemoryCredentialStore()
        transport = RoutingTransport([
            "POST /auth/sign-in": (.created, Fixtures.signedIn),
            "GET /me": (.ok, Fixtures.me),
            "POST /me/lock": (.noContent, ""),
            "POST /profiles/1/unlock": (.noContent, ""),
            "POST /profiles/2/unlock": (.noContent, ""),
        ])
        model = AppModel(store: store, deviceName: "Test Mac", transport: transport)
    }

    private func restore(_ me: String) async {
        store.server = URL(string: "https://media.example.test:8477")
        store.token = "old"
        transport.routes["GET /me"] = (.ok, me)
        await model.restore()
    }

    private func locked(_ me: String) -> String { String(me.dropLast()) + #","locked":true}"# }

    func testSigningInLocksBeforeWhoIsWatching() async throws {
        try await model.signIn(server: "rabbit.local", email: "a@example.test", password: "x")
        XCTAssertEqual(transport.paths(.post), ["/auth/sign-in", "/me/lock"])
        XCTAssertEqual(model.phase, .choosingProfile)
        XCTAssertTrue(model.locked)
    }

    func testSwitchingProfileLocksBeforeWhoIsWatchingShows() async throws {
        try await model.signIn(server: "rabbit.local", email: "a@example.test", password: "x")
        try await model.choose(try XCTUnwrap(model.profiles.first))
        XCTAssertFalse(model.locked)
        let arrived = expectation(description: "the lock is in flight")
        let release = DispatchSemaphore(value: 0)
        transport.respond = { sent in
            if sent.path == "/me/lock" {
                arrived.fulfill()
                release.wait()
            }
            return nil
        }
        let switching = Task { await model.switchProfile() }
        await fulfillment(of: [arrived], timeout: 5)
        XCTAssertEqual(model.phase, .browsing)
        release.signal()
        await switching.value
        XCTAssertEqual(model.phase, .choosingProfile)
        XCTAssertNil(model.activeProfile)
        XCTAssertTrue(model.locked)
    }

    func testALockThatFailsStillShowsWhoIsWatching() async throws {
        transport.routes["POST /me/lock"] = (.serviceUnavailable, Fixtures.error("internal"))
        try await model.signIn(server: "rabbit.local", email: "a@example.test", password: "x")
        try await model.choose(try XCTUnwrap(model.profiles.first))
        await model.switchProfile()
        XCTAssertEqual(model.phase, .choosingProfile)
        XCTAssertFalse(model.locked)
    }

    func testARestoredLockedDeviceLandsOnWhoIsWatchingWithoutLockingAgain() async {
        await restore(locked(Fixtures.me))
        XCTAssertEqual(model.phase, .choosingProfile)
        XCTAssertTrue(model.locked)
        XCTAssertEqual(transport.paths(.post), [])
    }

    func testADeviceLockedAnswerFromAnyCallReturnsToWhoIsWatching() async throws {
        try await model.signIn(server: "rabbit.local", email: "a@example.test", password: "x")
        try await model.choose(try XCTUnwrap(model.profiles.first))
        transport.routes["GET /libraries"] = (.forbidden, Fixtures.error("device_locked"))
        _ = try? await model.signedInClient().listLibraries()
        XCTAssertEqual(model.phase, .choosingProfile)
        XCTAssertNil(model.activeProfile)
        XCTAssertTrue(model.locked)
    }

    func testPickingAProfileUnlocksTheDeviceWithOrWithoutAPin() async throws {
        try await model.signIn(server: "rabbit.local", email: "a@example.test", password: "x")
        try await model.choose(try XCTUnwrap(model.profiles.first))
        XCTAssertEqual(model.phase, .browsing)
        XCTAssertFalse(model.locked)
        XCTAssertNil(transport.json(.post, "/profiles/1/unlock")?["pin"])
        await model.switchProfile()
        try await model.choose(try XCTUnwrap(model.profiles.last), pin: "1234")
        XCTAssertEqual(model.phase, .browsing)
        XCTAssertEqual(model.activeProfile?.id, 2)
        XCTAssertFalse(model.locked)
        XCTAssertEqual(transport.json(.post, "/profiles/2/unlock")?["pin"] as? String, "1234")
    }

    func testAddKidAtALockedPickerUnlocksTheAdultFirstAndLocksAgainOnClose() async throws {
        let pinned = Fixtures.account(1, "Avery", hasPin: true)
        await restore(locked(Fixtures.me.replacingOccurrences(of: Fixtures.adult, with: pinned)))
        XCTAssertTrue(model.canManageHousehold)
        XCTAssertTrue(model.isOwner)
        let adult = try XCTUnwrap(model.serverActiveProfile)
        try await model.unlock(adult, pin: "1234")
        XCTAssertFalse(model.locked)
        XCTAssertEqual(model.phase, .choosingProfile)
        XCTAssertEqual(transport.json(.post, "/profiles/1/unlock")?["pin"] as? String, "1234")
        await model.lock()
        XCTAssertTrue(model.locked)
        XCTAssertEqual(transport.paths(.post), ["/profiles/1/unlock", "/me/lock"])
    }
}
