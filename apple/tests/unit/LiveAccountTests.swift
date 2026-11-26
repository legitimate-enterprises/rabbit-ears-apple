import XCTest

@testable import RabbitEarsAPI
@testable import RabbitEarsKit

/// What a followed stream asks of the app model besides the catalog.
@MainActor
final class LiveAccountTests: XCTestCase {
    private func library(_ kind: String) -> String {
        #"{"id":1,"name":"L","kind":"\#(kind)","scanHour":3,"watchFiles":true,"folders":[],"#
            + #""stats":{"movies":0,"shows":0,"seasons":0,"episodes":0,"files":0,"bytes":0,"unmatched":0},"#
            + #""createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}"#
    }

    /// Follows a stream whose first poll answers `event`; the second finds it gone, which ends the following.
    private func follow(_ model: AppModel, _ transport: RoutingTransport, hearing event: String) async {
        var polls = 0
        transport.respond = { sent in
            guard sent.path == "/events" else { return nil }
            polls += 1
            return polls == 1 ? (.ok, Fixtures.events("c", [event])) : (.notFound, Fixtures.error("not_found"))
        }
        // Time for the first batch to be acted on before the following ends.
        transport.hold = { sent in if sent.path == "/events" { try await Task.sleep(for: .milliseconds(200)) } }
        await model.followLive(nil, inView: true)
    }

    func testAFinishedScanLoadsTheLibraryKindsAgain() async throws {
        let host = "libscan-\(UUID().uuidString.prefix(8).lowercased()).test"
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: "librarySections https://\(host)") }
        let transport = RoutingTransport([
            "POST /auth/sign-in": (.created, Fixtures.signedIn), "GET /me": (.ok, Fixtures.me),
            "GET /libraries": (.ok, Fixtures.page([library("tv")])),
        ])
        let model = AppModel(store: MemoryCredentialStore(), deviceName: "t", transport: transport)
        try await model.signIn(server: "https://\(host)", email: "a@example.test", password: "x")
        await model.loadLibrarySections()
        XCTAssertEqual(model.librarySections, [.tv])

        transport.routes["GET /libraries"] = (.ok, Fixtures.page([library("tv"), library("music")]))
        await follow(model, transport, hearing: #"{"kind":"library","libraryId":2}"#)
        XCTAssertEqual(model.librarySections, [.tv, .music])
    }

    func testAHouseholdEventReadsTheAccountAgain() async throws {
        let transport = RoutingTransport([
            "POST /auth/sign-in": (.created, Fixtures.signedIn), "GET /me": (.ok, Fixtures.me),
        ])
        let model = AppModel(store: MemoryCredentialStore(), deviceName: "t", transport: transport)
        try await model.signIn(server: "rabbit.local", email: "a@example.test", password: "x")
        let reads = { transport.paths(.get).filter { $0 == "/me" }.count }
        let before = reads()
        await follow(model, transport, hearing: #"{"kind":"household"}"#)
        XCTAssertGreaterThan(reads(), before)
    }
}
