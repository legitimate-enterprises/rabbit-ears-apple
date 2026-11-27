import Foundation
import GRDB
import HTTPTypes
import XCTest

@testable import RabbitEarsAPI
@testable import RabbitEarsKit

/// An app model over a replica directory of its own, whose server serves a
/// v1 snapshot of `rows` at version 1 and then has no changes.
@MainActor
final class SyncedApp {
    let fixture = ReplicaFixture()
    let transport = SyncTransport()
    let store = MemoryCredentialStore()
    private(set) var model: AppModel!
    var routes: RoutingTransport { transport.routes }

    init(signIn: String = Fixtures.signedIn, _ rows: (Database) throws -> Void = { _ in }) throws {
        routes.routes = [
            "POST /auth/sign-in": (.created, signIn), "GET /me": (.ok, Fixtures.me),
            "POST /me/lock": (.noContent, ""), "POST /auth/sign-out": (.noContent, ""),
            "PUT /me/household": (.noContent, ""),
        ]
        routes.respond = { sent in
            switch sent.path {
            case "/sync/changes":
                sent.query.contains("since=")
                    ? (.ok, SyncFixture.diff(version: 1)) : (.ok, SyncFixture.mode("snapshot"))
            case "/sync/actions": ActionQueueCase.answer(sent)
            default: nil
            }
        }
        try serve(rows)
        model = relaunch()
    }

    /// Another launch of the app on this device.
    func relaunch() -> AppModel {
        AppModel(store: store, deviceName: "Mac", transport: transport, replicaDirectory: fixture.directory)
    }

    func serve(_ rows: (Database) throws -> Void) throws { transport.snapshot = try fixture.v1File(rows) }

    func signIn() async throws {
        try await model.signIn(server: "rabbit.local", email: "a@example.test", password: "x")
    }

    /// Signed in, with the first snapshot adopted.
    func synced() async throws -> SyncSession {
        try await signIn()
        let sync = try XCTUnwrap(model.sync)
        // Joins the catch-up the sign-in started, which ends with the snapshot in, however long that takes.
        try await sync.engine.catchUp()
        XCTAssertFalse(sync.replica.isEmpty, "snapshot adopted")
        return sync
    }

    func until(_ condition: () async throws -> Bool) async rethrows {
        for _ in 0..<300 where try await !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func paths(_ method: HTTPRequest.Method) -> [String] { routes.paths(method) }

    func remove() { fixture.remove() }
}

@MainActor
final class AppModelSyncTests: XCTestCase {
    var app: SyncedApp!

    override func setUp() async throws { app = try SyncedApp { try $0.library(1, "tv") } }
    override func tearDown() { app.remove() }

    func testASignInOpensTheReplicaAndTakesASnapshotBeforeAnyViewFollows() async throws {
        _ = try await app.synced()
        XCTAssertEqual(app.routes.queries(.get, "/sync/snapshot"), ["schema=1"])
        await app.until { app.model.librarySections == [.tv] }
        XCTAssertEqual(app.model.librarySections, [.tv], "the sections are the replica's libraries")
        XCTAssertGreaterThan(app.model.live.library, 0)
    }

    func testASignOutSendsWhatIsQueuedThenDeletesTheReplicaAndTheQueue() async throws {
        let sync = try await app.synced()
        try await sync.replica.write { try $0.execute(sql: ReplicaFixture.enqueue("a")) }
        await app.model.signOut()
        XCTAssertEqual(app.model.phase, .signedOut)
        let posts = app.paths(.post)
        XCTAssertEqual(
            posts.filter { $0 == "/sync/actions" || $0 == "/auth/sign-out" }, ["/sync/actions", "/auth/sign-out"])
        XCTAssertFalse(app.fixture.exists(app.fixture.directory))
        XCTAssertNil(app.model.sync)
    }

    func testAFlushTheServerAnswersUnauthorizedSignsTheDeviceOut() async throws {
        let sync = try await app.synced()
        try await sync.replica.write { try $0.execute(sql: ReplicaFixture.enqueue("a")) }
        app.routes.respond = { [respond = app.routes.respond] sent in
            sent.path == "/sync/actions" ? (.unauthorized, Fixtures.error("unauthorized")) : respond?(sent)
        }

        sync.follow()

        await app.until { app.model.phase == .signedOut }
        XCTAssertEqual(app.model.phase, .signedOut)
        XCTAssertNil(app.model.sync)
    }

    func testALaunchOpensWhatIsKeptAndASignInStartsFromNothing() async throws {
        try await app.fixture.closedWithAnAction()
        app.routes.respond = nil
        app.store.server = URL(string: "http://rabbit.local:8477")
        app.store.token = "tok-1"
        await app.model.restore()
        XCTAssertEqual(app.model.sync?.replica.isEmpty, false, "kept across launches")
        XCTAssertEqual(try app.fixture.queuedActions(), ["a"])

        try await app.signIn()
        XCTAssertEqual(try app.fixture.queuedActions(), [], "another server or household's actions are not sent")
    }

    func testTheLastMeIsKeptForTheNextLaunchToOpenOnWhileTheServerIsDown() async throws {
        _ = try await app.synced()
        let next = app.relaunch()
        app.routes.routes["GET /me"] = (.internalServerError, Fixtures.error("internal"))
        await next.restore()
        XCTAssertEqual(next.phase, .choosingProfile)
        XCTAssertEqual(next.profiles.map(\.name), ["Avery", "Robin"])
    }

    func testMovingHouseholdSendsTheQueueFirstThenTakesANewSnapshot() async throws {
        app.remove()
        app = try SyncedApp(signIn: HouseholdChoiceTests.signedIn([(1, "Avery"), (2, "Mark")]))
        let sync = try await app.synced()
        try await sync.replica.write { try $0.execute(sql: ReplicaFixture.enqueue("a")) }
        try await app.model.chooseHousehold(app.model.households[1])
        let order = app.routes.sent.map { "\($0.method.rawValue) \($0.path)" }
            .filter { ["POST /sync/actions", "PUT /me/household", "GET /me"].contains($0) }
        XCTAssertEqual(order, ["POST /sync/actions", "PUT /me/household", "GET /me"])
        await app.until { app.routes.queries(.get, "/sync/snapshot").count == 2 }
        XCTAssertEqual(app.routes.queries(.get, "/sync/snapshot").count, 2, "the new household's replica")
    }

    func testAMoveIsRefusedWhileWhatIsQueuedCannotBeSent() async throws {
        app.remove()
        app = try SyncedApp(signIn: HouseholdChoiceTests.signedIn([(1, "Avery"), (2, "Mark")]))
        let sync = try await app.synced()
        try await sync.replica.write { try $0.execute(sql: ReplicaFixture.enqueue("a")) }
        app.routes.respond = nil
        app.routes.routes["POST /sync/actions"] = (.internalServerError, Fixtures.error("internal"))
        do {
            try await app.model.chooseHousehold(app.model.households[1])
            XCTFail("moved with actions unsent")
        } catch {}
        XCTAssertFalse(app.paths(.put).contains("/me/household"))
        XCTAssertEqual(app.model.phase, .choosingHousehold)
    }

    func testARefusedActionIsNamedInPlainWords() async throws {
        let sync = try await app.synced()
        app.routes.respond = { sent in
            sent.path == "/sync/actions" ? ActionQueueCase.answer(sent, rejecting: ["putWatchState": "forbidden"]) : nil
        }
        try await sync.replica.write { try $0.execute(sql: ReplicaFixture.enqueue("a")) }
        _ = await sync.queue.flush()
        await app.until { app.model.live.notice != nil }
        XCTAssertEqual(app.model.live.notice, "Couldn't save watch progress.")
        XCTAssertEqual(SyncSession.rejected("createPlaylistShare"), "Couldn't save a playlist share.")
        XCTAssertEqual(SyncSession.rejected("disallowItem"), "Couldn't save an allow list.")
        XCTAssertEqual(SyncSession.rejected("lockDevice"), "Couldn't save a change.")
    }

    func testAServerThatNoLongerSyncsWithThisBuildIsToldOnce() async throws {
        app.routes.respond = { sent in
            sent.path == "/sync/changes" ? (.ok, SyncFixture.mode("unsupported")) : nil
        }
        try await app.signIn()
        let sync = try XCTUnwrap(app.model.sync)
        await app.until { app.model.live.notice != nil }
        XCTAssertEqual(app.model.live.notice, "Update Rabbit Ears to keep this device in sync.")
        XCTAssertTrue(sync.engine.unsupported)
    }

    func testAQueueLostToDamageIsToldAtOpen() async throws {
        try await app.fixture.closedWithAnAction()
        try ReplicaFixture.breakHeader(app.fixture.queue)
        app.store.server = URL(string: "http://rabbit.local:8477")
        app.store.token = "tok-1"
        await app.model.restore()
        XCTAssertEqual(app.model.live.notice, "Some changes made offline were lost.")
    }

    func testEveryViewFollowingSharesOneSyncLoop() async throws {
        _ = try await app.synced()
        app.routes.hold = { sent in if sent.path == "/sync/version" { try await Task.sleep(for: .seconds(30)) } }
        let first = Task { await app.model.followLive(nil, inView: true) }
        let second = Task { await app.model.followLive(nil, inView: true) }
        await app.until { !app.routes.queries(.get, "/sync/version").isEmpty }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(app.routes.queries(.get, "/sync/version"), ["after=1"])
        first.cancel()
        second.cancel()
        await first.value
        await second.value
    }
}
