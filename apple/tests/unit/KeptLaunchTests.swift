import Foundation
import HTTPTypes
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// A launch opens on the Me and the answers kept from the last one, and the
/// server's answers update them in place once they come.
@MainActor
final class KeptLaunchTests: XCTestCase {
    let directory = FileManager.default.temporaryDirectory.appending(path: "Kept launch \(UUID().uuidString)")
    var store: MemoryCredentialStore!
    var transport: RoutingTransport!

    override func setUp() async throws {
        store = MemoryCredentialStore()
        transport = RoutingTransport([
            "POST /auth/sign-in": (.created, Fixtures.signedIn),
            "GET /me": (.ok, Fixtures.me),
            "POST /me/lock": (.noContent, ""),
            "POST /profiles/1/unlock": (.noContent, ""),
            "POST /profiles/2/unlock": (.noContent, ""),
            "GET /items": (.ok, Fixtures.page([Fixtures.item(20, "movie", "Dune")])),
            "GET /profiles/1/watch-state": (.ok, Fixtures.page([])),
        ])
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func model(remembering: Bool = true) -> AppModel {
        AppModel(
            store: store, deviceName: "Test Mac", rememberProfileByDefault: remembering, transport: transport,
            cache: ResponseCache(directory: directory))
    }

    /// Signs in, browses as Avery once so the library is kept, and returns
    /// the model the next launch makes, over a server that holds every
    /// answer until `gate` opens.
    private func relaunch(remembering: Bool = true, gate: Gate) async throws -> AppModel {
        let first = model(remembering: remembering)
        try await first.signIn(server: "rabbit.local", email: "a@example.test", password: "x")
        try await first.choose(try XCTUnwrap(first.profiles.first { $0.id == 1 }))
        await CatalogModel(client: try XCTUnwrap(first.client), profileId: 1).load()
        transport = RoutingTransport(transport.routes)
        transport.hold = { _ in try await gate.wait() }
        return model(remembering: remembering)
    }

    private func soon(_ done: () -> Bool) async throws {
        for _ in 0..<200 where !done() { try await Task.sleep(for: .milliseconds(5)) }
    }

    func testALaunchBrowsesTheKeptLibraryBeforeTheServerAnswers() async throws {
        let gate = Gate()
        defer { gate.open() }
        let next = try await relaunch(gate: gate)
        let launch = Task { await next.restore() }
        try await soon { next.phase == .browsing }
        XCTAssertEqual(next.phase, .browsing, "before the server answered Me")
        XCTAssertEqual(next.activeProfile?.id, 1)
        let catalog = CatalogModel(client: try XCTUnwrap(next.client), profileId: 1)
        let started = ContinuousClock.now
        await catalog.load()
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
        XCTAssertEqual(catalog.catalog.item(20)?.parsedTitle, "Dune")
        gate.open()
        await launch.value
        XCTAssertEqual(next.phase, .browsing)
        XCTAssertEqual(transport.paths(.post), [], "the server still had Avery active")
    }

    func testALaunchShowsWhoIsWatchingBeforeTheServerAnswersAndUnlocksOnlyAfterTheLock() async throws {
        let gate = Gate()
        defer { gate.open() }
        let next = try await relaunch(remembering: false, gate: gate)
        let launch = Task { await next.restore() }
        try await soon { next.phase == .choosingProfile }
        XCTAssertEqual(next.phase, .choosingProfile, "before the server answered Me or the lock")
        XCTAssertEqual(next.profiles.map(\.id), [1, 2])
        let pick = Task { try await next.choose(try XCTUnwrap(next.profiles.first { $0.id == 1 })) }
        try await Task.sleep(for: .milliseconds(50))
        gate.open()
        try await pick.value
        await launch.value
        XCTAssertEqual(next.phase, .browsing)
        XCTAssertFalse(next.locked)
        XCTAssertEqual(transport.paths(.post), ["/me/lock", "/profiles/1/unlock"])
    }

    func testWithTheServerUnreachableALaunchKeepsBrowsingTheKeptLibrary() async throws {
        let gate = Gate()
        gate.open()
        let next = try await relaunch(gate: gate)
        transport.failure = URLError(.cannotConnectToHost)
        await next.restore()
        XCTAssertEqual(next.phase, .browsing)
        let catalog = CatalogModel(client: try XCTUnwrap(next.client), profileId: 1)
        await catalog.load()
        XCTAssertEqual(catalog.catalog.item(20)?.parsedTitle, "Dune")
    }

    func testTheServersMeReplacesTheKeptOneInPlace() async throws {
        let gate = Gate()
        gate.open()
        let next = try await relaunch(gate: gate)
        transport.routes["GET /me"] = (.ok, Fixtures.me.replacingOccurrences(of: #""Avery""#, with: #""Ava""#))
        await next.restore()
        XCTAssertEqual(next.phase, .browsing)
        XCTAssertEqual(next.activeProfile?.name, "Ava")
    }

    func testAServerAnsweringAsAnotherProfileTakesTheLaunchAsItWouldHaveGone() async throws {
        let gate = Gate()
        gate.open()
        let next = try await relaunch(gate: gate)
        transport.routes["GET /me"] = (.ok, String(Fixtures.me.dropLast()) + #","locked":true}"#)
        await next.restore()
        XCTAssertEqual(next.phase, .browsing)
        XCTAssertEqual(next.activeProfile?.id, 1)
        XCTAssertFalse(next.locked)
        XCTAssertEqual(transport.paths(.post), ["/profiles/1/unlock"])
    }

    func testARevokedTokenFoundAfterTheKeptLaunchSignsOut() async throws {
        let gate = Gate()
        gate.open()
        let next = try await relaunch(gate: gate)
        transport.routes["GET /me"] = (.unauthorized, Fixtures.error("unauthorized"))
        await next.restore()
        XCTAssertEqual(next.phase, .signedOut)
        XCTAssertNil(store.token)
        XCTAssertNil(next.me)
        XCTAssertNil(ResponseCache(directory: directory).me(for: try XCTUnwrap(store.server)))
    }

    func testWhetherTheServerAnswersIsAskedPastWhatIsKept() async throws {
        let gate = Gate()
        gate.open()
        let next = try await relaunch(gate: gate)
        transport.routes["GET /health"] = (.ok, #"{"status":"ok","version":"0.17.0","setupRequired":false}"#)
        await next.restore()
        let up = await next.serverAnswers()
        XCTAssertTrue(up)
        transport.failure = URLError(.cannotConnectToHost)
        let catalog = CatalogModel(client: try XCTUnwrap(next.client), profileId: 1)
        await catalog.load()
        XCTAssertNotNil(catalog.catalog.item(20), "the kept library still reads")
        let down = await next.serverAnswers()
        XCTAssertFalse(down, "but the server is not answering")
    }

    func testLockingAndUnlockingLeaveTheKeptAnswersStanding() async throws {
        let gate = Gate()
        gate.open()
        let next = try await relaunch(remembering: false, gate: gate)
        await next.restore()
        try await next.choose(try XCTUnwrap(next.profiles.first { $0.id == 1 }))
        let slow = Gate()
        defer { slow.open() }
        transport.hold = { _ in try await slow.wait() }
        let catalog = CatalogModel(client: try XCTUnwrap(next.client), profileId: 1)
        let started = ContinuousClock.now
        await catalog.load()
        XCTAssertLessThan(started.duration(to: .now), .seconds(1), "answered from what is kept")
        XCTAssertEqual(catalog.catalog.item(20)?.parsedTitle, "Dune")
    }
}
