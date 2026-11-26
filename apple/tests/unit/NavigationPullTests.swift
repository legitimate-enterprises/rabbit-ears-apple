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

    func testAPullReloadsAndReadsTheLibrariesAgain() async throws {
        let host = "pull-\(UUID().uuidString.prefix(8).lowercased()).test"
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: "librarySections https://\(host)") }
        let transport = RoutingTransport([
            "POST /auth/sign-in": (.created, Fixtures.signedIn),
            "GET /me": (.ok, Fixtures.me),
            "GET /libraries": (.ok, Fixtures.page([])),
        ])
        let model = AppModel(store: MemoryCredentialStore(), deviceName: "t", transport: transport)
        try await model.signIn(server: "https://\(host)", email: "a@example.test", password: "x")
        var reloaded = false
        await model.pull { reloaded = true }
        XCTAssertTrue(reloaded)
        XCTAssertEqual(model.librarySections, [])
    }
}
