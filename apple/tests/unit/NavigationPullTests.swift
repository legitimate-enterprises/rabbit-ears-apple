import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

@MainActor
final class NavigationPullTests: XCTestCase {
    func testASelectedSectionThatLeavesFallsBackToHome() {
        let visible = LibrarySection.visible(for: [.movies, .tv])
        XCTAssertEqual(LibrarySection.selection(.tv, in: visible), .tv)
        XCTAssertNil(LibrarySection.selection(.music, in: visible), "Home")
        XCTAssertNil(LibrarySection.selection(nil, in: []), "Home stays with nothing else")
    }

    func testAPullCatchesUpThenReadsTheLibrariesAgain() async throws {
        let app = try SyncedApp { try $0.library(1, "tv") }
        defer { app.remove() }
        _ = try await app.synced()
        await app.until { app.model.librarySections == [.tv] }
        app.routes.respond = { sent in
            sent.path == "/sync/changes"
                ? (
                    .ok,
                    SyncFixture.diff(
                        version: 2,
                        tables: [.init("library", #"["id","name","kind"]"#, #"[["\#(UID.n(2))","M","music"]]"#)])
                )
                : nil
        }
        var reloaded = false
        await app.model.pull { reloaded = true }
        XCTAssertTrue(reloaded)
        XCTAssertEqual(app.model.librarySections, [.tv, .music])
    }
}
