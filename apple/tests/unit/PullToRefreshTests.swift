import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// A pull asks the server rather than reading what is kept, and returns once the new data is in.
extension ResponseCacheTests {
    func testAPullAsksTheServerAndReturnsOnlyOnceTheCatalogHasTheNewAnswer() async throws {
        let live = LiveFeed(cache: cache)
        let model = CatalogModel(client: client, profileId: 1)
        await model.load()
        XCTAssertNotNil(model.catalog.item(20))

        listsNext(21)
        await live.pull { await model.load() }
        XCTAssertNotNil(model.catalog.item(21), "not the kept answer")
        XCTAssertNil(model.catalog.item(20))
    }

    func testAPullRereadsLoadedRowsInPlaceFromTheServer() async throws {
        let live = LiveFeed(cache: cache)
        let client = client!
        let pager = Pager<Int64> { _ in
            (try await client.listItems(query: .init(kind: .movie)).ok.body.json.items.map(\.id), nil)
        }
        await pager.loadMore()
        XCTAssertEqual(pager.items, [20])

        listsNext(21)
        await live.pull { await pager.refresh() }
        XCTAssertEqual(pager.items, [21])
    }

    func testAPullTheSystemCancelsStillFinishesApplyingTheNewData() async throws {
        let live = LiveFeed(cache: cache)
        let model = CatalogModel(client: client, profileId: 1)
        await model.load()

        listsNext(21)
        let pull = Task { await live.pull { await model.load() } }
        pull.cancel()
        await pull.value
        XCTAssertNotNil(model.catalog.item(21))
    }

    func testAFailedPullKeepsWhatWasShown() async throws {
        let live = LiveFeed(cache: cache)
        let model = CatalogModel(client: client, profileId: 1)
        await model.load()

        transport.routes["GET /items"] = (.internalServerError, Fixtures.error("internal"))
        await live.pull { await model.load() }
        XCTAssertNotNil(model.catalog.item(20), "the kept answer stands in while the server fails")
    }
}
