import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// The shared models speak as an iPhone when the iOS app builds them.
@MainActor
final class PlatformTests: XCTestCase {
    func testSignInAndAcceptNameTheIOSPlatform() async throws {
        let transport = RoutingTransport([
            "POST /auth/sign-in": (.created, Fixtures.signedIn),
            "POST /join/ABCD-EFGH": (.created, Fixtures.signedIn),
        ])
        let model = AppModel(
            store: MemoryCredentialStore(), deviceName: "iPhone", platform: .ios, transport: transport)
        try await model.signIn(server: "rabbit.local", email: "a@example.test", password: "secret")
        let signIn = try XCTUnwrap(transport.body(.post, "/auth/sign-in"))
        XCTAssertEqual(Fixtures.decode(signIn, as: Components.Schemas.SignInRequest.self).platform, .ios)
        try await model.acceptJoin(server: "rabbit.local", code: "abcd-efgh", name: "Sam", password: "x")
        let accept = try XCTUnwrap(transport.body(.post, "/join/ABCD-EFGH"))
        XCTAssertEqual(Fixtures.decode(accept, as: Components.Schemas.AcceptRequest.self).platform, .ios)
    }

    func testRunningOutOfPlanNamesThisIPhone() async {
        let transport = RoutingTransport([
            "POST /playback/sessions": (.created, Fixtures.stream()),
            "PUT /playback/sessions/7/position": (.noContent, ""),
            "POST /playback/sessions/7/events": (.conflict, Fixtures.error("conflict", "no entry left")),
        ])
        let endpoint = ServerEndpoint(userInput: "media.example.test")!
        let item = Fixtures.decode(Fixtures.item(5, "movie", "Arrival"), as: Item.self)
        let model = PlayerModel(
            client: endpoint.client(token: "t", transport: transport), endpoint: endpoint, profileId: 1, item: item,
            output: FakeOutput(), capabilities: FakeCapabilities(), device: "iPhone", fetchText: { _ in "" })
        await model.start()
        await model.playerFailed("Cannot decode")
        XCTAssertEqual(model.error, "This title can't play on this iPhone.")
    }
}
