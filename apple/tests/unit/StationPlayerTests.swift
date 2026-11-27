import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

@MainActor
final class StationPlayerTests: XCTestCase {
    func testTheStreamEndingAsksTheStationWhatIsOnNext() async throws {
        let transport = RoutingTransport(["DELETE /playback/sessions/7": (.noContent, "")])
        let onAir = Fixtures.onAir("on_air", now: Fixtures.lantern, position: 4_328_000, next: Fixtures.salt)
        transport.routes["POST /stations/5/playback"] = (
            .created, #"{"stream":\#(Fixtures.stream(session: 7, position: 4_328_000)),"onAir":\#(onAir)}"#
        )
        let server = ServerEndpoint(userInput: "192.168.1.9")!
        let client = server.client(token: "t", transport: transport)
        let tuner = stationTuner(
            client: client, replica: try tunerReplica(), station: Fixtures.decode(Fixtures.bigScreen))
        defer { tuner.cancel() }
        let player = PlayerModel(
            client: client, endpoint: server, profileId: 1, item: nil, output: FakeOutput(),
            capabilities: FakeCapabilities())
        let output = AVPlayerOutput()
        var asks: Int { transport.paths(.post).filter { $0 == "/stations/5/playback" }.count }
        await player.tune(tuner, on: output)
        XCTAssertEqual(asks, 1)
        output.onEnd?()
        for _ in 0..<200 where asks < 2 { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(asks, 2)
    }
}
