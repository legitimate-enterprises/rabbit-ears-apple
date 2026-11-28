import Foundation
import GRDB
import XCTest

@testable import RabbitEarsKit

/// A launch reads no replica that lacks a table, view or column this build
/// reads: it takes a fresh snapshot first, keeping what is queued.
@MainActor
final class LaunchPreflightTests: XCTestCase {
    var app: SyncedApp!

    override func setUp() async throws {
        app = try SyncedApp { try $0.account(1, "Avery") }
        app.store.server = URL(string: "http://rabbit.local:8477")
        app.store.token = "tok-1"
    }

    override func tearDown() { app.remove() }

    /// The replica and one queued action the last launch left, its v1 schema changed by `older`.
    private func kept(_ older: (Database) throws -> Void = { _ in }) async throws {
        let replica = try app.fixture.v1(older)
        try await replica.write { try $0.execute(sql: ReplicaFixture.enqueue("a")) }
    }

    private static let withoutProfileArt = { (db: Database) in try db.execute(sql: "DROP VIEW profile_art") }

    func testTheKitExpectsWhatTheSchemaFixtureDeclares() throws {
        let declared = try DatabaseQueue().write { db in
            try db.execute(sql: ReplicaSchema.v1)
            return try Row.fetchAll(
                db,
                sql: """
                    SELECT m.name, p.name AS col FROM sqlite_master m, pragma_table_info(m.name) p
                    WHERE m.type IN ('table', 'view')
                    """
            ).reduce(into: [String: Set<String>]()) { $0[$1["name"], default: []].insert($1["col"]) }
        }
        XCTAssertEqual(Replica.shipped, declared)
    }

    func testOnlyAReplicaLackingATableViewOrColumnIsDropped() async throws {
        let sound = try app.fixture.v1()
        XCTAssertFalse(sound.dropOutdated())
        XCTAssertFalse(sound.isEmpty)
        let other = ReplicaFixture()
        addTeardownBlock { other.remove() }
        let shorter = try other.v1 { db in
            try db.execute(
                sql: """
                    DROP TABLE smart_list;
                    CREATE TABLE smart_list (id BLOB, playlist_id BLOB, created_at INTEGER, PRIMARY KEY (id));
                    """)
        }
        XCTAssertTrue(shorter.dropOutdated(), "a column missing")
        XCTAssertTrue(shorter.isEmpty)
    }

    func testALaunchOverAReplicaLackingAViewTakesASnapshotBeforeAnyViewAndKeepsTheQueue() async throws {
        try await kept(Self.withoutProfileArt)
        app.routes.routes["POST /sync/actions"] = (.internalServerError, Fixtures.error("internal"))
        let respond = app.routes.respond
        app.routes.respond = { sent in sent.path == "/sync/actions" ? nil : respond?(sent) }
        let model = try XCTUnwrap(app.model)
        let phases = Log<AppModel.Phase>()
        app.routes.hold = { sent in if sent.path == "/sync/snapshot" { phases.add(await model.phase) } }

        await model.restore()

        XCTAssertEqual(phases.all, [.starting], "the snapshot came before any view")
        XCTAssertNotEqual(model.phase, .starting)
        XCTAssertNil(model.libraryUpdate)
        let replica = try XCTUnwrap(model.sync?.replica)
        let art = try await replica.read { try $0.viewExists("profile_art") }
        XCTAssertTrue(art, "the views read a replica that has profile_art")
        XCTAssertEqual(try app.fixture.queuedActions().prefix(1), ["a"], "what is queued outlives the replica")
    }

    func testAReplicaReplacedAsOutdatedIsReportedOnceThereIsOne() async throws {
        try await kept(Self.withoutProfileArt)
        unsendable()

        await app.model.restore()

        try await app.until { try app.fixture.queuedOperations().contains("reportClientErrors") }
        XCTAssertEqual(try app.fixture.queuedOperations(), ["putWatchState", "reportClientErrors"])
        let text = try reported()
        XCTAssertTrue(text.contains(#""launch.preflight""#), text)
    }

    func testAReplicaThatFailsToOpenIsReported() async throws {
        try await app.fixture.closedWithAnAction()
        try ReplicaFixture.breakHeader(app.fixture.directory.appending(path: app.fixture.current()))
        unsendable()

        await app.model.restore()

        try await app.until { try app.fixture.queuedOperations().contains("reportClientErrors") }
        let text = try reported()
        XCTAssertTrue(text.contains(#""launch.replica""#), text)
    }

    /// Every flush fails, so what is queued stays to be read.
    private func unsendable() {
        app.routes.routes["POST /sync/actions"] = (.internalServerError, Fixtures.error("internal"))
        let respond = app.routes.respond
        app.routes.respond = { sent in sent.path == "/sync/actions" ? nil : respond?(sent) }
    }

    /// The bodies of the queued error reports, as JSON text.
    private func reported() throws -> String {
        try DatabaseQueue(path: app.fixture.queue.path(percentEncoded: false)).read {
            try Data.fetchAll($0, sql: "SELECT body FROM action WHERE operation_id = 'reportClientErrors'")
        }.map { String(bytes: $0, encoding: .utf8) ?? "" }.joined(separator: "\n")
    }

    func testALaunchOverASoundReplicaTakesNoSnapshot() async throws {
        try await kept()
        await app.model.restore()
        XCTAssertEqual(app.model.sync?.replica.isEmpty, false)
        await app.until { app.routes.paths(.get).contains("/sync/changes") }
        XCTAssertEqual(app.routes.queries(.get, "/sync/snapshot"), [])
    }

    func testOfflineALaunchOverAnOutdatedReplicaWaitsOnTheSplashForATryAgain() async throws {
        try await kept(Self.withoutProfileArt)
        app.routes.failure = URLError(.notConnectedToInternet)

        await app.model.restore()

        XCTAssertEqual(app.model.phase, .starting)
        XCTAssertEqual(app.model.libraryUpdate, .unreachable)
        XCTAssertEqual(app.model.sync?.replica.isEmpty, true, "nothing reads the outdated replica")
        XCTAssertEqual(try app.fixture.queuedActions(), ["a"])

        app.routes.failure = nil
        await app.model.retryLibraryUpdate()

        XCTAssertNil(app.model.libraryUpdate)
        XCTAssertNotEqual(app.model.phase, .starting)
        XCTAssertEqual(app.routes.queries(.get, "/sync/snapshot"), ["schema=1"])
    }

    func testALockedDeviceGoesOnToWhosWatchingWithNoReplicaUntilAProfileIsPicked() async throws {
        try await kept(Self.withoutProfileArt)
        let respond = app.routes.respond
        app.routes.respond = { sent in
            sent.path == "/sync/changes" ? (.forbidden, Fixtures.error("device_locked")) : respond?(sent)
        }

        await app.model.restore()

        XCTAssertNil(app.model.libraryUpdate)
        XCTAssertNotEqual(app.model.phase, .starting)
        XCTAssertEqual(app.model.sync?.replica.isEmpty, true)
        XCTAssertEqual(try app.fixture.queuedActions(), ["a"])
    }
}
