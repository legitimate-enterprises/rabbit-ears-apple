import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// Home's On now and occasion rows arrive after Home first shows; each
/// holds its space as the last Home this launch showed it until its own
/// answer comes.
@MainActor
final class HomeSlotsTests: XCTestCase {
    var store: MemoryCredentialStore!
    var transport: RoutingTransport!
    var model: AppModel?

    override func setUp() async throws {
        store = MemoryCredentialStore()
        transport = RoutingTransport([
            "POST /auth/sign-in": (.created, Fixtures.signedIn),
            "GET /me": (.ok, Fixtures.me),
            "POST /me/lock": (.noContent, ""),
            "POST /profiles/1/unlock": (.noContent, ""),
        ])
    }

    /// Browsing as Avery; signed in once, and again after a sign-out.
    private func browsing() async throws -> AppModel {
        let model =
            model
            ?? AppModel(store: store, deviceName: "Test Mac", transport: transport, replicaDirectory: Fixtures.replicas)
        self.model = model
        if model.phase != .browsing {
            try await model.signIn(server: "rabbit.local", email: "a@example.test", password: "x")
            try await model.choose(try XCTUnwrap(model.profiles.first { $0.id == 1 }))
        }
        return model
    }

    private func station(_ id: Int64, kind: String) -> Station {
        Fixtures.decode(
            Fixtures.station(
                id, "S\(id)", kind: kind,
                onAir: Fixtures.onAir("on_air", now: Fixtures.program(30, "Paper Lanterns", kind: "song"))))
    }

    private func shelf(_ id: Int64, _ name: String, tiles: Int) -> OccasionShelf {
        let occasion: ActiveOccasion = Fixtures.decode(
            #"{"id":\#(id),"name":"\#(name)","anchorDate":"2026-12-25","#
                + #""firstDate":"2026-12-01","lastDate":"2026-12-31"}"#)
        return OccasionShelf(
            occasion: occasion, items: (0..<tiles).map { Fixtures.decode(Fixtures.item(Int64(100 + $0), "movie", "M")) }
        )
    }

    func testWithNothingShownBeforeNoSpaceIsHeld() async throws {
        let model = try await browsing()
        let slots = model.homeSlots(1)
        XCTAssertNil(slots.onNow(answered: false))
        XCTAssertEqual(slots.occasions(answered: false), [])
    }

    func testTheNextHomeHoldsTheRowsTheLastOneShowedUntilEachAnswers() async throws {
        let first = try await browsing()
        first.homeShowed(onNow: [station(8, kind: "music"), station(9, kind: "movies")], profileId: 1)
        first.homeShowed(occasions: [shelf(2, "Halloween Nights", tiles: 3)], profileId: 1)

        let next = try await browsing().homeSlots(1)
        XCTAssertEqual(next.onNow(answered: false), HomeSlot(row: .onNow, title: "On now", wide: [false, true]))
        XCTAssertEqual(
            next.occasions(answered: false),
            [HomeSlot(row: .occasion(2), title: "Halloween Nights", wide: [false, false, false])])
        XCTAssertNil(next.onNow(answered: true), "the answer replaces it")
        XCTAssertEqual(next.occasions(answered: true), [])
    }

    func testARowTheLastHomeFoundEmptyHoldsNothingNextTime() async throws {
        let first = try await browsing()
        first.homeShowed(onNow: [station(8, kind: "music")], profileId: 1)
        first.homeShowed(occasions: [shelf(2, "Halloween Nights", tiles: 3)], profileId: 1)
        first.homeShowed(onNow: [], profileId: 1)
        first.homeShowed(occasions: [], profileId: 1)

        let next = try await browsing().homeSlots(1)
        XCTAssertNil(next.onNow(answered: false))
        XCTAssertEqual(next.occasions(answered: false), [])
    }

    func testEachProfileHoldsOnlyWhatItsOwnHomeShowed() async throws {
        let model = try await browsing()
        model.homeShowed(onNow: [station(8, kind: "music")], profileId: 1)
        XCTAssertNil(model.homeSlots(2).onNow(answered: false))
        model.homeShowed(onNow: [station(9, kind: "music")], profileId: 2)
        XCTAssertEqual(model.homeSlots(1).onNow(answered: false)?.wide, [false], "only the active profile's is kept")
    }

    func testOccasionsAnswerOnceTheReplicaSaysWhetherAnyAreInSeasonOrCannotBeRead() async throws {
        let fixture = ReplicaFixture()
        defer { fixture.remove() }
        let occasions = OccasionsModel()
        XCTAssertFalse(occasions.answered)
        await occasions.load(replica: try fixture.v1 { try $0.account(1, "Avery") }, profileId: 1)
        XCTAssertTrue(occasions.answered)
        let failed = OccasionsModel()
        await failed.load(replica: Replica(directory: Fixtures.replicas), profileId: 1)
        XCTAssertTrue(failed.answered, "nothing to show, so the space it held collapses")
    }

    func testSigningOutForgetsWhatHomeShowed() async throws {
        let model = try await browsing()
        model.homeShowed(onNow: [station(8, kind: "music")], profileId: 1)
        await model.signOut()
        let again = try await browsing()
        XCTAssertNil(again.homeSlots(1).onNow(answered: false))
    }
}
