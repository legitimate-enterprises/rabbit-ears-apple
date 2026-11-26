import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

extension PlayerModelTests {
    func testTheForcedTracksLateTextNeverReplacesATrackPickedMeanwhile() async throws {
        serveSubtitles()
        let gate = Gate()
        let model = PlayerModel(
            client: server.client(token: "t", transport: transport), endpoint: server, profileId: 2,
            item: Fixtures.decode(Fixtures.item(20, "movie", "Dune"), as: Item.self), output: output,
            capabilities: capabilities,
            fetchText: { url in
                if url.lastPathComponent == "4.vtt" { try await gate.wait() }
                return "WEBVTT\n\n00:00:01.000 --> 00:00:09.000\n\(url.lastPathComponent)\n"
            })
        let starting = Task { await model.start() }
        for _ in 0..<500 where model.stream == nil { try await Task.sleep(for: .milliseconds(2)) }
        await model.selectSubtitles(.track(5))
        XCTAssertEqual(model.cue(at: 2), "5.vtt")
        gate.open()
        await starting.value
        XCTAssertEqual(model.cue(at: 2), "5.vtt")
    }
}
