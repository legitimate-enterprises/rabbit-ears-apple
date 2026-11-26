import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

@MainActor
final class PlayerStartTests: XCTestCase {
    func testARequestStartsItsTrackEditionAndPosition() async throws {
        let transport = RoutingTransport(["POST /playback/sessions": (.created, Fixtures.stream(position: 90_000))])
        let server = ServerEndpoint(userInput: "192.168.1.9")!
        let item = Fixtures.decode(Fixtures.item(20, "movie", "Dune"), as: Item.self)
        let output = FakeOutput()
        let model = PlayerModel(
            client: server.client(token: "t", transport: transport), endpoint: server, profileId: 2, item: item,
            output: output, capabilities: FakeCapabilities())
        await model.start(PlayRequest(item: item, audioTrackId: 3, editionId: 6, positionMs: 90_000))
        let body = try XCTUnwrap(transport.json(.post, "/playback/sessions"))
        XCTAssertEqual(body["audioTrackId"] as? Int, 3)
        XCTAssertEqual(body["editionId"] as? Int, 6)
        XCTAssertEqual(body["positionMs"] as? Int, 90_000)
        XCTAssertEqual(output.loaded.count, 1)
    }
}
