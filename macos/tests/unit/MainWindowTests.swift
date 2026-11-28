import AppKit
import RabbitEarsAPI
import SwiftUI
import XCTest

@testable import RabbitEarsKit

/// The main window closed and opened again, as the Dock and the Window menu do, with the app running on.
@MainActor
final class MainWindowTests: XCTestCase {
    private var model: AppModel!
    private var app: MainWindowState!

    override func setUp() async throws {
        let transport = RoutingTransport([
            "POST /auth/sign-in": (.created, Fixtures.signedIn),
            "GET /me": (.ok, Fixtures.me),
            "POST /me/lock": (.noContent, ""),
            "POST /profiles/\(UID.n(1))/unlock": (.noContent, ""),
        ])
        model = AppModel(
            store: MemoryCredentialStore(), deviceName: "Test Mac", transport: transport,
            replicaDirectory: Fixtures.replicas)
        app = MainWindowState()
        try await model.signIn(server: "127.0.0.1", email: "a@example.test", password: "x")
        try await model.choose(model.profiles[0])
    }

    func testClosingTheLastWindowLeavesTheAppRunning() {
        XCTAssertFalse(AppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    func testMusicPlaysOnWithTheWindowClosedAndInTheWindowOpenedAgain() async throws {
        var first: MusicPlayer?
        let window = try await show { first = $0 }
        let player = try XCTUnwrap(first)
        close(window)
        try await settle()
        XCTAssertTrue(app.music === player, "the closed window's music outlives it")

        var second: MusicPlayer?
        close(try await show { second = $0 })
        XCTAssertTrue(second === player, "the window opened again plays the same music")
    }

    func testLeavingTheProfileEndsItsMusic() async throws {
        let window = try await show { _ in }
        XCTAssertNotNil(app.music)
        await model.switchProfile()
        close(window)
        try await settle()
        XCTAssertNil(app.music)
    }

    private func show(entered: @escaping (MusicPlayer) -> Void) async throws -> NSWindow {
        let controller = NSHostingController(
            rootView: AnyView(
                MainView(nowPlaying: SystemNowPlayingCenter { _ in nil }, entered: entered)
                    .environment(model).environment(app)))
        controller.sizingOptions = []
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 1200, height: 760),
            styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        try await settle()
        return window
    }

    private func close(_ window: NSWindow) {
        window.close()
        window.contentViewController = nil
    }

    private func settle() async throws { try await Task.sleep(for: .seconds(1)) }
}
