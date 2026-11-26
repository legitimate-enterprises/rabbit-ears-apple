import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

@MainActor
final class CarPlayImagesTests: XCTestCase {
    func testOwnImagesStandForPlaylistsAndStations() async throws {
        let transport = RoutingTransport()
        let client = ServerEndpoint(userInput: "192.168.1.9")!.client(token: "t", transport: transport)
        let library = CarPlayLibrary(music: MusicModel(client: client, profileId: 1))
        let station = Fixtures.station(
            8, "Kitchen Radio", kind: "music",
            onAir: Fixtures.onAir("on_air", now: Fixtures.program(30, "Paper Lanterns", kind: "song"))
        ).replacingOccurrences(of: #""onAir":"#, with: #""imageUrl":"/api/v1/stations/8/image?v=1","onAir":"#)
        let playlist = Fixtures.playlist(3, "Road trip", count: 48).replacingOccurrences(
            of: #""durationMs""#, with: #""imageUrl":"/api/v1/profiles/1/playlists/3/image?v=2","durationMs""#)
        transport.routes = [
            "GET /profiles/1/playlists": (.ok, Fixtures.page([playlist])),
            "GET /stations": (.ok, Fixtures.page([station])),
        ]
        let list = try await library.playlists(CarPlayLimits(maxItems: 500, maxSections: 50, limited: false))
        XCTAssertEqual(list.sections.first?.rows.first?.art, .custom("/api/v1/stations/8/image?v=1"))
        XCTAssertEqual(list.sections.last?.rows.first?.art, .custom("/api/v1/profiles/1/playlists/3/image?v=2"))
    }
}
