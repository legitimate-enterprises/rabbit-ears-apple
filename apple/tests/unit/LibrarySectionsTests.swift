import XCTest

@testable import RabbitEarsAPI
@testable import RabbitEarsKit

@MainActor
final class LibrarySectionsTests: XCTestCase {
    func testVisibleIsEverySectionUntilKindsAreKnown() {
        XCTAssertEqual(LibrarySection.visible(for: nil), Set(LibrarySection.allCases))
        XCTAssertEqual(LibrarySection.visible(for: [.movies, .movies, .music]), [.movies, .music])
        XCTAssertEqual(LibrarySection.visible(for: []), [])
    }

    func testTheSectionsAreTheReplicasLibrariesAndEveryOneBeforeItsFirstSnapshot() async throws {
        let app = try SyncedApp { try $0.library(1, "tv") }
        defer { app.remove() }
        let gate = Gate()
        app.routes.hold = { sent in if sent.path == "/sync/snapshot" { try await gate.wait() } }
        try await app.signIn()
        XCTAssertEqual(app.model.librarySections, Set(LibrarySection.allCases))
        gate.open()
        await app.until { app.model.librarySections == [.tv] }
        XCTAssertEqual(app.model.librarySections, [.tv])

        let relaunch = app.relaunch()
        app.routes.failure = URLError(.cannotConnectToHost)
        await relaunch.restore()
        XCTAssertEqual(relaunch.librarySections, [.tv], "kept, with the server unreachable")
    }

    func testALibraryTheReplicaGainsShowsItsSection() async throws {
        let app = try SyncedApp { try $0.library(1, "tv") }
        defer { app.remove() }
        let sync = try await app.synced()
        await app.until { app.model.librarySections == [.tv] }
        try await sync.replica.write { try $0.library(2, "music") }
        await app.until { app.model.librarySections == [.tv, .music] }
        XCTAssertEqual(app.model.librarySections, [.tv, .music])
    }
}
