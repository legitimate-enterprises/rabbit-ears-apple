import Foundation
import GRDB
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

@MainActor
final class CarPlayImagesTests: XCTestCase {
    func testOwnImagesStandForPlaylistsAndStations() async throws {
        let transport = RoutingTransport()
        let library = try carPlay(transport) { db in
            try kitchenRadio(db)
            try db.cover(77, station: 8, item: nil)
            try db.playlist(3, "Road trip", kind: "music")
            try db.cover(2, on: 3)
        }
        let list = try await library.playlists(CarPlayLimits(maxItems: 500, maxSections: 50, limited: false))
        XCTAssertEqual(list.sections.first?.rows.first?.art, .custom("/api/v1/stations/8/image?v=77"))
        XCTAssertEqual(list.sections.last?.rows.first?.art, .custom("/api/v1/profiles/1/playlists/3/image?v=2"))
    }
}
