import AppKit
import RabbitEarsAPI
import SwiftUI
import XCTest

@testable import RabbitEarsKit

/// The kit's player modifier, which every Apple client's video player wears, in a real window.
@MainActor
final class PlayerTeardownTests: XCTestCase {
    func testAPlayerThatGoesAwayEndsItsSession() async throws {
        let transport = RoutingTransport()
        let app = AppModel(store: MemoryCredentialStore(), deviceName: "Test Mac", transport: transport)
        let request = PlayRequest(item: Fixtures.decode(Fixtures.item(21, "episode", "Pilot"), as: Item.self))
        let model = PlayerModel(
            client: ServerEndpoint.default.client(token: "t", transport: transport), endpoint: .default,
            profileId: 1, item: request.item, output: FakeOutput(), capabilities: FakeCapabilities())
        let live = PlayerLive(request: request, model: model, browser: Browser(), leave: {}, finish: {})
        let controller = NSHostingController(rootView: AnyView(Color.clear.modifier(live).environment(app)))
        controller.sizingOptions = []
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.close() }
        try await settle()
        XCTAssertFalse(model.stopped)
        controller.rootView = AnyView(Color.clear)
        try await settle()
        XCTAssertTrue(model.stopped)
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(300)) }
}
