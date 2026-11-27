import Foundation
import HTTPTypes
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// A launch opens on the Me kept from the last one and the replica, and
/// the server's answers update them in place once they come.
@MainActor
final class KeptLaunchTests: XCTestCase {
    var app: SyncedApp!
    /// What was sent before the relaunch.
    var mark = 0

    override func setUp() async throws {
        app = try SyncedApp { db in
            try db.account(1, "Avery")
            try db.item(20, "movie", "Dune")
        }
        app.routes.routes["POST /profiles/1/unlock"] = (.noContent, "")
        app.routes.routes["POST /profiles/2/unlock"] = (.noContent, "")
    }

    override func tearDown() async throws {
        app.routes.hold = nil
        app.remove()
    }

    private func model(remembering: Bool = true) -> AppModel {
        AppModel(
            store: app.store, deviceName: "Test Mac", rememberProfileByDefault: remembering, transport: app.transport,
            replicaDirectory: app.fixture.directory)
    }

    /// Signs in, browses as Avery once with the first snapshot taken, and
    /// returns the model the next launch makes, over a server that holds
    /// every answer until `gate` opens.
    private func relaunch(remembering: Bool = true, gate: Gate) async throws -> AppModel {
        let first = model(remembering: remembering)
        try await first.signIn(server: "rabbit.local", email: "a@example.test", password: "x")
        try await first.choose(try XCTUnwrap(first.profiles.first { $0.id == 1 }))
        // The next launch opens what this one adopted, so it must be in first.
        try await XCTUnwrap(first.sync).engine.catchUp()
        mark = app.routes.sent.count
        app.routes.hold = { _ in try await gate.wait() }
        return model(remembering: remembering)
    }

    private var posts: [String] { app.routes.sent.dropFirst(mark).filter { $0.method == .post }.map(\.path) }

    private func catalog(_ model: AppModel) throws -> CatalogModel {
        CatalogModel(
            client: try XCTUnwrap(model.client), replica: try XCTUnwrap(model.sync?.replica), profileId: 1)
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
        let catalog = try catalog(next)
        let started = ContinuousClock.now
        await catalog.load()
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
        XCTAssertEqual(catalog.catalog.item(20)?.parsedTitle, "Dune")
        gate.open()
        await launch.value
        XCTAssertEqual(next.phase, .browsing)
        XCTAssertEqual(posts, [], "the server still had Avery active")
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
        XCTAssertEqual(posts, ["/me/lock", "/profiles/1/unlock"])
    }

    func testWithTheServerUnreachableALaunchKeepsBrowsingTheKeptLibrary() async throws {
        let gate = Gate()
        gate.open()
        let next = try await relaunch(gate: gate)
        app.routes.failure = URLError(.cannotConnectToHost)
        await next.restore()
        XCTAssertEqual(next.phase, .browsing)
        let catalog = try catalog(next)
        await catalog.load()
        XCTAssertEqual(catalog.catalog.item(20)?.parsedTitle, "Dune")
    }

    func testTheServersMeReplacesTheKeptOneInPlace() async throws {
        let gate = Gate()
        gate.open()
        let next = try await relaunch(gate: gate)
        app.routes.routes["GET /me"] = (.ok, Fixtures.me.replacingOccurrences(of: #""Avery""#, with: #""Ava""#))
        await next.restore()
        XCTAssertEqual(next.phase, .browsing)
        XCTAssertEqual(next.activeProfile?.name, "Ava")
    }

    func testAServerAnsweringAsAnotherProfileTakesTheLaunchAsItWouldHaveGone() async throws {
        let gate = Gate()
        gate.open()
        let next = try await relaunch(gate: gate)
        app.routes.routes["GET /me"] = (.ok, String(Fixtures.me.dropLast()) + #","locked":true}"#)
        await next.restore()
        XCTAssertEqual(next.phase, .browsing)
        XCTAssertEqual(next.activeProfile?.id, 1)
        XCTAssertFalse(next.locked)
        XCTAssertEqual(posts, ["/profiles/1/unlock"])
    }

    func testARevokedTokenFoundAfterTheKeptLaunchSignsOut() async throws {
        let gate = Gate()
        gate.open()
        let next = try await relaunch(gate: gate)
        app.routes.routes["GET /me"] = (.unauthorized, Fixtures.error("unauthorized"))
        await next.restore()
        XCTAssertEqual(next.phase, .signedOut)
        XCTAssertNil(app.store.token)
        XCTAssertNil(next.me)
        await app.until { !app.fixture.exists(app.fixture.directory) }
        XCTAssertFalse(app.fixture.exists(app.fixture.directory), "nor the kept Me")
    }

    func testWhetherTheServerAnswersIsAskedPastWhatIsKept() async throws {
        let gate = Gate()
        gate.open()
        let next = try await relaunch(gate: gate)
        app.routes.routes["GET /health"] = (.ok, #"{"status":"ok","version":"0.17.0","setupRequired":false}"#)
        await next.restore()
        let up = await next.serverAnswers()
        XCTAssertTrue(up)
        app.routes.failure = URLError(.cannotConnectToHost)
        let catalog = try catalog(next)
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
        app.routes.hold = { _ in try await slow.wait() }
        let catalog = try catalog(next)
        let started = ContinuousClock.now
        await catalog.load()
        XCTAssertLessThan(started.duration(to: .now), .seconds(1), "answered from what is kept")
        XCTAssertEqual(catalog.catalog.item(20)?.parsedTitle, "Dune")
    }
}
