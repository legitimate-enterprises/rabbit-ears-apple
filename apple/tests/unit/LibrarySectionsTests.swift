import XCTest

@testable import RabbitEarsAPI
@testable import RabbitEarsKit

@MainActor
final class LibrarySectionsTests: XCTestCase {
    private func library(_ kind: String) -> String {
        #"{"id":1,"name":"L","kind":"\#(kind)","scanHour":3,"watchFiles":true,"folders":[],"#
            + #""stats":{"movies":0,"shows":0,"seasons":0,"episodes":0,"files":0,"bytes":0,"unmatched":0},"#
            + #""createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}"#
    }

    func testVisibleIsEverySectionUntilKindsAreKnown() {
        XCTAssertEqual(LibrarySection.visible(for: nil), Set(LibrarySection.allCases))
        XCTAssertEqual(LibrarySection.visible(for: [.movies, .movies, .music]), [.movies, .music])
        XCTAssertEqual(LibrarySection.visible(for: []), [])
    }

    func testTheServersKindsAreRememberedAndAFailedAnswerKeepsThem() async throws {
        let host = "libsec-\(UUID().uuidString.prefix(8).lowercased()).test"
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: "librarySections https://\(host)") }
        let transport = RoutingTransport([
            "POST /auth/sign-in": (.created, Fixtures.signedIn),
            "GET /me": (.ok, Fixtures.me),
            "GET /libraries": (.ok, Fixtures.page([library("tv")])),
        ])
        let model = AppModel(store: MemoryCredentialStore(), deviceName: "t", transport: transport)
        try await model.signIn(server: "https://\(host)", email: "a@example.test", password: "x")
        XCTAssertEqual(model.librarySections, Set(LibrarySection.allCases))
        await model.loadLibrarySections()
        XCTAssertEqual(model.librarySections, [.tv])

        let relaunch = AppModel(store: MemoryCredentialStore(), deviceName: "t", transport: transport)
        try await relaunch.signIn(server: "https://\(host)", email: "a@example.test", password: "x")
        XCTAssertEqual(relaunch.librarySections, [.tv])

        transport.routes["GET /libraries"] = (.internalServerError, Fixtures.error("internal"))
        await relaunch.loadLibrarySections()
        XCTAssertEqual(relaunch.librarySections, [.tv])
    }
}
