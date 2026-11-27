import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

@MainActor
private final class Cover: VideoBrowser {
    var playing: PlayRequest?
    /// What the viewer plays instead while a request is in flight.
    var instead: PlayRequest?

    func moveOn() { playing = instead }
}

@MainActor
final class PlayerExitTests: XCTestCase {
    var transport: RoutingTransport!
    var client: Client!
    private var cover: Cover!
    var closed = 0
    var fixture: ReplicaFixture!
    /// Alpha's pilot (21), and its second episode (22) once `answerSecond` adds it.
    var replica: Replica!
    let avery = Fixtures.decode(Fixtures.adult, as: Account.self)
    let pilot = PlayRequest(item: Fixtures.decode(Fixtures.item(21, "episode", "Pilot"), as: Item.self))

    override func setUp() async throws {
        transport = RoutingTransport()
        let server = ServerEndpoint(userInput: "192.168.1.9")!
        client = server.client(token: "t", transport: transport)
        cover = Cover()
        cover.playing = pilot
        closed = 0
        fixture = ReplicaFixture()
        replica = try library(second: false)
    }

    override func tearDown() { fixture.remove() }

    private func library(second: Bool) throws -> Replica {
        try fixture.v1 { db in
            try db.account(1, "Avery")
            try db.item(10, "show", "Alpha", rating: "TV-14")
            try db.item(11, "season", "Season 1", parent: 10, season: 1)
            try db.item(21, "episode", "Pilot", parent: 11, season: 1, episode: 1)
            if second {
                try db.item(22, "episode", "Second", parent: 11, season: 1, episode: 2)
                try db.playable(22)
            }
        }
    }

    private func exit(_ request: PlayRequest) -> PlayerExit {
        let server = ServerEndpoint(userInput: "192.168.1.9")!
        let model = PlayerModel(
            client: client, endpoint: server, profileId: 1, item: request.item, output: FakeOutput(),
            capabilities: FakeCapabilities())
        return PlayerExit(
            request: request, model: model, catalog: CatalogModel(client: client, replica: replica, profileId: 1),
            browser: cover
        ) { [unowned self] in
            closed += 1
            cover.playing = nil
        }
    }

    private func answerSecond() throws {
        fixture.remove()
        fixture = ReplicaFixture()
        replica = try library(second: true)
    }

    func testLeavingClosesThePlayer() {
        exit(pilot).leave()
        XCTAssertEqual(closed, 1)
        XCTAssertNil(cover.playing)
    }

    func testUpNextPlaysInTheSameCover() {
        let next = PlayRequest(
            id: pilot.id, item: Fixtures.decode(Fixtures.item(22, "episode", "Second"), as: Item.self))
        exit(pilot).playNext(next)
        XCTAssertEqual(cover.playing?.item.id, 22)
        XCTAssertEqual(closed, 0)
    }

    func testAnEndWithSomethingNextOffersIt() async throws {
        try answerSecond()
        let next = await exit(pilot).ended(client: client, profile: avery)
        XCTAssertEqual(next?.request.item.id, 22)
        XCTAssertEqual(closed, 0)
    }

    func testAnEndWithNothingNextClosesThePlayer() async {
        let next = await exit(pilot).ended(client: client, profile: avery)
        XCTAssertNil(next)
        XCTAssertEqual(closed, 1)
    }

    func testALookupAnsweredAfterTheViewerMovedOnLeavesTheNewPlayerUp() async {
        let other = PlayRequest(item: Fixtures.decode(Fixtures.item(30, "movie", "Other"), as: Item.self))
        let cover = cover!
        cover.instead = other
        // Back, then another title, before the lookup answers.
        cover.moveOn()
        let next = await exit(pilot).ended(client: client, profile: avery)
        XCTAssertNil(next)
        XCTAssertEqual(closed, 0)
        XCTAssertEqual(cover.playing?.id, other.id)
    }

    func testALookupAnsweredAfterNextEpisodeOffersNothingOverIt() async throws {
        let second = PlayRequest(
            id: pilot.id, item: Fixtures.decode(Fixtures.item(22, "episode", "Second"), as: Item.self))
        let cover = cover!
        cover.instead = second
        cover.moveOn()
        try answerSecond()
        let next = await exit(pilot).ended(client: client, profile: avery)
        XCTAssertNil(next)
        XCTAssertEqual(closed, 0)
    }

    func testAnEndSignedOutClosesThePlayer() async {
        let next = await exit(pilot).ended(client: nil, profile: nil)
        XCTAssertNil(next)
        XCTAssertEqual(closed, 1)
    }
}
