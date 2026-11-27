import Foundation
import GRDB
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// The server's seeded fixture, as household 201's replica: Wide (703) is a
/// server-wide station of account 111 of household 202, which the replica
/// lacks; it brings its own playlist (512) and Lent (403), 202's custom
/// collection one of its entries names. Small (704) plays Bo's (102)
/// playlist 513. None of them is listed but where the server lists it.
@MainActor
final class ForeignRowsTests: XCTestCase {
    var synced: SyncedReplica!

    override func setUp() async throws { synced = try SyncedReplica(sample: true) }
    override func tearDown() { synced.remove() }

    func testTheSampleHoldsTheForeignRowsButNotTheirOwner() async throws {
        let held: [UID] = try await synced.read(
            """
            SELECT id FROM station WHERE id = \(sqlID(703)) UNION ALL SELECT id FROM playlist WHERE id = \(sqlID(512))
            UNION ALL SELECT id FROM collection WHERE id = \(sqlID(403))
            UNION ALL SELECT id FROM account WHERE id = \(sqlID(111))
            """)
        XCTAssertEqual(held, [703, 512, 403])
    }

    func testPlaylistsAreTheProfilesOwnAndThoseReachingIt() async {
        let ada = synced.playlists(101)
        await ada.load()
        XCTAssertEqual(ada.playlists.map(\.id), [501])
        let bo = synced.playlists(102)
        await bo.load()
        XCTAssertEqual(bo.playlists.map(\.id), [513])
        let di = synced.playlists(104, adult: false)
        await di.load()
        XCTAssertEqual(di.playlists.map(\.id), [501], "shared with her")
        let entries = await ada.entries(of: 512)
        XCTAssertNil(entries)
        let order = await ada.playOrder(of: 513)
        XCTAssertNil(order)
        XCTAssertEqual(ada.error, AppError.server("not found").localizedDescription)
    }

    func testCollectionsAreTheHouseholdsOwnAndTMDBs() async {
        let model = synced.collections(101)
        await model.load()
        XCTAssertEqual(model.collections.map(\.id), [401])
        let holding = await model.collections(of: 1)
        XCTAssertEqual(holding.map(\.id), [401], "Lent holds it too")
        let lent = await model.movies(of: 403)
        XCTAssertNil(lent)
    }

    func testRelatedCollectionsAreTheHouseholdsOwnAndTMDBs() async throws {
        let catalog = CatalogModel(client: synced.client, replica: synced.replica, profileId: 101)
        let related = try await unwrapped(await catalog.related(1))
        XCTAssertEqual(related.collections.map(\.collection.id), [401])
    }

    func testStationsListAnotherHouseholdsServerWideOneWithItsOwnersHousehold() async throws {
        let ada = stationsModel(synced.replica, profile: 101)
        let all = await ada.list()
        XCTAssertEqual(all?.map(\.id), [706, 702, 704, 703])
        let wide = try XCTUnwrap(all?.last)
        XCTAssertEqual([wide.ownerId, wide.householdId], [111, 202])
        XCTAssertFalse(ada.isOwner(wide))
        let di = await stationsModel(synced.replica, profile: 104).list()
        XCTAssertEqual(di?.map(\.id), [706, 703])
    }
}
