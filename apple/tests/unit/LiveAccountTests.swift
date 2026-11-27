import XCTest

@testable import RabbitEarsAPI
@testable import RabbitEarsKit

/// What a commit to the replica asks of the app model besides the catalog.
@MainActor
final class LiveAccountTests: XCTestCase {
    func testAHouseholdChangeReadsTheAccountAgainWhileFollowing() async throws {
        let app = try SyncedApp()
        defer { app.remove() }
        let sync = try await app.synced()
        let following = Task { await app.model.followLive(nil, inView: true) }
        let reads = { app.paths(.get).filter { $0 == "/me" }.count }
        try await Task.sleep(for: .milliseconds(50))
        let before = reads()
        try await sync.replica.write { try $0.account(9, "Sam") }
        await app.until { reads() > before }
        XCTAssertGreaterThan(reads(), before)
        following.cancel()
        await following.value
    }
}
