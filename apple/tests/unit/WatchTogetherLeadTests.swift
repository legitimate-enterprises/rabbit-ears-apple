import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// What a member tells the server about its link, and keeping the poll held.
@MainActor
final class WatchTogetherLeadTests: XCTestCase {
    var transport: RoutingTransport!
    var model: WatchTogetherModel!
    var output: FakeOutput!
    let clock = Date(timeIntervalSince1970: 1_000_000)

    override func setUp() async throws {
        transport = RoutingTransport()
        output = FakeOutput()
        model = WatchTogetherModel(
            client: ServerEndpoint(userInput: "192.168.1.9")!.client(token: "t", transport: transport),
            profileId: 1, itemId: 20, now: { [unowned self] in clock })
    }

    func testTheLatestQuickRoundTripIsReportedOnHeldPollsAndActions() async {
        transport.routes["POST /watch-together"] = (
            .created, Fixtures.together(status: "joined", joined: true, version: 2)
        )
        await model.open()
        model.attach(output)
        transport.routes["GET /watch-together/\(UID.n(5))"] = (
            .ok, Fixtures.together(status: "joined", joined: true, version: 2)
        )
        transport.routes["PUT /watch-together/\(UID.n(5))/state"] = (
            .ok, Fixtures.together(status: "joined", joined: true, playing: true, version: 3)
        )
        await model.play()
        await model.poll(held: true)
        await model.poll()
        await model.poll(held: true)
        await model.play()
        XCTAssertEqual(
            transport.queries(.put, "/watch-together/\(UID.n(5))/state"), ["", "rttMs=0"],
            "the first action had no round trip to report")
        XCTAssertEqual(
            transport.queries(.get, "/watch-together/\(UID.n(5))"), ["after=3&rttMs=0", "rttMs=0", "after=3&rttMs=0"])
    }

    func testAHoldThatRanOutIsAskedAgainAtOnce() async throws {
        var ticks = 0.0
        let ticking = WatchTogetherModel(
            client: ServerEndpoint(userInput: "192.168.1.9")!.client(token: "t", transport: transport),
            profileId: 1, itemId: 20,
            now: {
                ticks += 30
                return Date(timeIntervalSince1970: 1_000_000 + ticks)
            })
        transport.routes["POST /watch-together"] = (.created, Fixtures.together(host: (1, "Avery")))
        transport.routes["GET /watch-together/\(UID.n(5))"] = (
            .ok, Fixtures.together(status: "joined", joined: true, version: 2)
        )
        await ticking.open()
        let running = Task { await ticking.run() }
        try await Task.sleep(for: .milliseconds(400))
        running.cancel()
        await running.value
        let held = transport.queries(.get, "/watch-together/\(UID.n(5))").filter { $0.contains("after=") }
        XCTAssertGreaterThan(held.count, 2, "an unchanged answer that took 30 s waits for nothing")
    }
}
