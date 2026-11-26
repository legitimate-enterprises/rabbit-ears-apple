import AppKit
import RabbitEarsAPI
import SwiftUI
import XCTest

@testable import RabbitEarsKit

/// The real window's views, laid out and drawn offscreen.
@MainActor
final class MiniPlayerTests: XCTestCase {
    func testTheMiniPlayerShowsUnderAPushedPage() async throws {
        let transport = RoutingTransport([
            "POST /auth/sign-in": (.created, Fixtures.signedIn),
            "GET /me": (.ok, Fixtures.me),
            "POST /profiles/1/unlock": (.noContent, ""),
            "GET /music/albums/50": (.ok, Fixtures.album(50, "In Rainbows")),
            "GET /music/albums": (.ok, Fixtures.page([])),
            "GET /music/songs": (.ok, Fixtures.page([Fixtures.song(1, "15 Step", track: 1)])),
            "POST /playback/sessions": (.created, Fixtures.audioStream(1)),
        ])
        let model = AppModel(store: MemoryCredentialStore(), deviceName: "Test Mac", transport: transport)
        // A loopback server, so the player's stream fails at once rather than reaching the network.
        try await model.signIn(server: "127.0.0.1", email: "a@example.test", password: "x")
        try await model.choose(model.profiles[0])
        let browser = Browser()
        var player: MusicPlayer?
        let controller = NSHostingController(
            rootView: MainView(
                nowPlaying: SystemNowPlayingCenter { _ in nil }, entered: { player = $0 }, browser: browser
            )
            .environment(model))
        controller.sizingOptions = []
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 1200, height: 760),
            styleMask: [.titled, .resizable, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(.init(width: 1200, height: 760))
        defer { window.close() }
        try await settle()
        browser.open(.album(50))
        try await settle()

        // As the album's Play does.
        let detail = try await XCTUnwrap(model.musicModel).album(50)
        try await XCTUnwrap(player).play(detail.songs, source: detail.album.title)
        try await settle()

        let frame = try XCTUnwrap(window.contentView?.superview)
        let bitmap = try XCTUnwrap(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
        frame.cacheDisplay(in: frame.bounds, to: bitmap)
        // Both points are clear of any text: one in the page's empty middle, one inside the bar's
        // 60 points at the window's bottom.
        let scale = bitmap.pixelsHigh / Int(frame.bounds.height)
        let column = bitmap.pixelsWide - 4 * scale
        let page = bitmap.colorAt(x: column, y: bitmap.pixelsHigh / 2)
        let bottom = bitmap.colorAt(x: column, y: bitmap.pixelsHigh - 10 * scale)
        XCTAssertNotNil(page)
        XCTAssertNotEqual(page, bottom, "the mini player's raised bar, not the page, at the window's bottom")
    }

    private func settle() async throws { try await Task.sleep(for: .seconds(1)) }
}
