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
        XCTAssertEqual(
            list.sections.first?.rows.first?.art, .custom("/api/v2/stations/\(UID.n(8))/image?v=\(UID.n(77))"))
        XCTAssertEqual(
            list.sections.last?.rows.first?.art,
            .custom("/api/v2/profiles/\(UID.n(1))/playlists/\(UID.n(3))/image?v=\(UID.n(2))"))
    }
}
