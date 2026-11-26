import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

@MainActor
final class StationPlayerTests: XCTestCase {
    func testTheStreamEndingAsksTheStationWhatIsOnNext() async {
        let transport = RoutingTransport([
            "GET /stations/5": (
                .ok,
                Fixtures.station(5, "The Big Screen", onAir: Fixtures.onAir("between_programs", next: Fixtures.salt))
            ),
            "DELETE /playback/sessions/7": (.noContent, ""),
        ])
        let onAir = Fixtures.onAir("on_air", now: Fixtures.lantern, position: 4_328_000, next: Fixtures.salt)
        transport.routes["POST /stations/5/playback"] = (
            .created, #"{"stream":\#(Fixtures.stream(session: 7, position: 4_328_000)),"onAir":\#(onAir)}"#
        )
        let server = ServerEndpoint(userInput: "192.168.1.9")!
        let client = server.client(token: "t", transport: transport)
        let tuner = StationTuner(client: client, station: Fixtures.decode(Fixtures.bigScreen)) { _ in
            try await Task.sleep(for: .seconds(3600))
        }
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
