import AppKit
import RabbitEarsAPI
import SwiftUI
import XCTest

@testable import RabbitEarsKit

/// The real window's views, with the process-wide transport watched from outside.
@MainActor
final class TransportTests: XCTestCase {
    func testAnOpenVideoOrStationTakesTheSystemsTransportFromTheMusic() async throws {
        let transport = RoutingTransport([
            "POST /auth/sign-in": (.created, Fixtures.signedIn),
            "GET /me": (.ok, Fixtures.me),
            "POST /profiles/\(UID.n(1))/unlock": (.noContent, ""),
            "GET /playback/sessions": (.ok, Fixtures.page([])),
            "POST /playback/sessions": (.created, Fixtures.audioStream(1)),
        ])
        let model = AppModel(
            store: MemoryCredentialStore(), deviceName: "Test Mac", transport: transport,
            replicaDirectory: Fixtures.replicas)
        // A loopback server, so the player's stream fails at once rather than reaching the network.
        try await model.signIn(server: "127.0.0.1", email: "a@example.test", password: "x")
        try await model.choose(model.profiles[0])
        let browser = Browser()
        let center = SystemNowPlayingCenter { _ in nil }
        let controller = NSHostingController(
            rootView: MainView(nowPlaying: center, browser: browser).environment(model)
                .environment(MainWindowState()))
        controller.sizingOptions = []
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 1200, height: 760),
            styleMask: [.titled, .resizable, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(.init(width: 1200, height: 760))
        defer { window.close() }
        try await settle()
        XCTAssertNotNil(center.onCommand, "the music answers the system's transport while nothing else is open")

        browser.playing = PlayRequest(item: Fixtures.decode(Fixtures.item(20, "movie", "Dune"), as: Item.self))
        try await settle()
        XCTAssertNil(center.onCommand, "Play on a media key must not start the album over a movie")
        XCTAssertEqual(
            transport.queries(.get, "/playback/sessions"), ["itemId=\(UID.n(20))"], "the shared handoff gate is mounted"
        )

        browser.playing = nil
        try await settle()
        XCTAssertNotNil(center.onCommand)

        browser.tuning = Fixtures.decode(Fixtures.bigScreen, as: Station.self)
        try await settle()
        XCTAssertNil(center.onCommand)
        browser.tuning = nil
        try await settle()
        XCTAssertNotNil(center.onCommand)
    }

    private func settle() async throws { try await Task.sleep(for: .seconds(1)) }
}
