import Foundation
import HTTPTypes
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

@MainActor
final class PlaylistSharesTests: XCTestCase {
    func testASharedPlaylistSaysWhoAndWhatTheProfileMayDo() {
        let decode = { (json: String) in Fixtures.decode(json, as: Playlist.self) }
        let own = decode(Fixtures.playlist(3, "Mine"))
        XCTAssertTrue(own.isOwned)
        XCTAssertTrue(own.isEditable)
        XCTAssertNil(own.sharedBy)
        let read = decode(Fixtures.playlist(4, "Theirs", access: "read", ownerName: "Ann"))
        XCTAssertFalse(read.isOwned)
        XCTAssertFalse(read.isEditable)
        XCTAssertEqual(read.sharedBy, "Shared by Ann")
        let write = decode(Fixtures.playlist(5, "Ours", access: "write", ownerName: "Ann"))
        XCTAssertFalse(write.isOwned)
        XCTAssertTrue(write.isEditable)
    }

    func testAKidGetsAPlaylistsViewOnlyForWhatIsSharedAndAddsToNone() async throws {
        let synced = try SyncedReplica { db in
            try db.account(1, "Avery")
            try db.account(2, "Kit", kind: "kid")
            try db.card(9, "Ann")
            try db.playlist(3, "Theirs", owner: 9)
            try db.playlist(4, "Ours", owner: 9)
            try db.playlist(5, "Mine")
            try db.share(3, with: 1, "read")
            try db.share(3, with: 2, "read")
            try db.share(4, with: 1, "write")
        }
        addTeardownBlock { await synced.remove() }
        let kid = synced.playlists(2, adult: false)
        await kid.load()
        XCTAssertTrue(kid.offersView(.movies))
        XCTAssertFalse(kid.offersView(.music))
        XCTAssertEqual(kid.editable(.movies).map(\.id), [])

        let adult = synced.playlists(1)
        await adult.load()
        XCTAssertTrue(adult.offersView(.music))
        XCTAssertEqual(adult.editable(.movies).map(\.id), [5, 4])
    }

    private var synced: SyncedReplica?

    override func tearDown() async throws { await synced?.remove() }

    private func model(_ routes: [String: (HTTPResponse.Status, String)]) throws -> (
        PlaylistSharesModel, RoutingTransport
    ) {
        let synced = try SyncedReplica { db in
            try db.account(1, "Avery")
            try db.playlist(3, "Mix")
        }
        self.synced = synced
        synced.transport.routes = routes
        return (
            PlaylistSharesModel(client: synced.client, queue: synced.queue, profileId: 1, playlistId: 3),
            synced.transport
        )
    }

    private static func household(_ id: UID, _ name: String, profiles: Int) -> String {
        #"{"id":"\#(id)","name":"\#(name)","profiles":\#(profiles)}"#
    }

    private static func householdShare(_ id: UID, _ name: String, access: String = "read") -> String {
        #"{"playlistId":"\#(UID.n(3))","householdId":"\#(id)","name":"\#(name)","access":"\#(access)","#
            + #""createdAt":"2026-01-01T00:00:00Z"}"#
    }

    /// In household 7, Home, unless told otherwise.
    private static func candidate(
        _ id: UID, _ name: String, kind: String = "adult", household: UID = 7, householdName: String = "Home",
        color: String = "#2E6B5B"
    ) -> String {
        #"{"profileId":"\#(id)","name":"\#(name)","kind":"\#(kind)","householdId":"\#(household)","#
            + #""householdName":"\#(householdName)","color":"\#(color)"}"#
    }

    func testListsHouseholdsAndProfilesWithWhatEachMayDo() async throws {
        let (model, _) = try model([
            "GET /profiles/\(UID.n(1))/share-households": (
                .ok,
                Fixtures.page([
                    Self.household(7, "Mark's household", profiles: 4),
                    Self.household(8, "Heidi's household", profiles: 1),
                ])
            ),
            "GET /profiles/\(UID.n(1))/playlists/\(UID.n(3))/household-shares": (
                .ok, Fixtures.page([Self.householdShare(7, "Mark's household")])
            ),
            "GET /profiles/\(UID.n(1))/playlists/\(UID.n(3))/shares": (
                .ok,
                Fixtures.page([
                    Fixtures.share(2, "Heidi", access: "write"),
                    Fixtures.share(9, "Gone", kind: "kid", household: 8),
                ])
            ),
            "GET /profiles/\(UID.n(1))/share-candidates": (
                .ok,
                Fixtures.page([
                    Self.candidate(2, "Heidi", household: 8, householdName: "Heidi's household", color: "#6B3A2E"),
                    Self.candidate(4, "Jax", kind: "kid", household: 8, householdName: "Heidi's household"),
                    Self.candidate(5, "Pat", household: 9, householdName: "Heidi's household"),
                ])
            ),
        ])
        await model.load()
        XCTAssertNil(model.error)
        XCTAssertEqual(model.households.map(\.name), ["Mark's household", "Heidi's household"])
        XCTAssertEqual(model.households.map(\.profilesLabel), ["4 profiles", "1 profile"])
        XCTAssertEqual(model.households.map { model.access($0) }, [.read, nil])
        XCTAssertEqual(
            model.profiles.map(\.name), ["Heidi", "Jax", "Pat", "Gone"], "a share outside the candidates stays")
        XCTAssertEqual(
            model.profiles.map(\.subtitle),
            ["Heidi's household", "Heidi's household · Kid", nil, "Heidi's household · Kid"],
            "only a household of the owner's is named, by id")
        XCTAssertEqual(model.profiles.map(\.rgb), [0x6B3A2E, 0x2E6B5B, 0x2E6B5B, nil])
        XCTAssertEqual(model.profiles.map { model.access($0) }, [.write, nil, nil, .read])
        XCTAssertEqual(model.profiles.map(\.choices), [[.read, .write], [.read], [.read, .write], [.read]])
        XCTAssertEqual(PlaylistShareAccess?.none.label, "Not shared")
        XCTAssertEqual(PlaylistShareAccess?.some(.write).label, "Can edit")
    }

    func testOneHouseholdGoesUnnamed() async throws {
        let (model, _) = try model([
            "GET /profiles/\(UID.n(1))/share-households": (
                .ok, Fixtures.page([Self.household(7, "Home", profiles: 3)])
            ),
            "GET /profiles/\(UID.n(1))/playlists/\(UID.n(3))/household-shares": (.ok, Fixtures.page([])),
            "GET /profiles/\(UID.n(1))/playlists/\(UID.n(3))/shares": (.ok, Fixtures.page([])),
            "GET /profiles/\(UID.n(1))/share-candidates": (
                .ok,
                Fixtures.page([
                    Self.candidate(2, "Sam"),
                    Self.candidate(4, "Jax", kind: "kid"),
                ])
            ),
        ])
        await model.load()
        XCTAssertEqual(model.profiles.map(\.subtitle), [nil, "Kid"])
    }

    func testEachChangeIsQueuedAndShowsAtOnce() async throws {
        let (model, transport) = try model([
            "GET /profiles/\(UID.n(1))/share-households": (
                .ok, Fixtures.page([Self.household(7, "Home", profiles: 3)])
            ),
            "GET /profiles/\(UID.n(1))/playlists/\(UID.n(3))/household-shares": (.ok, Fixtures.page([])),
            "GET /profiles/\(UID.n(1))/playlists/\(UID.n(3))/shares": (.ok, Fixtures.page([])),
            "GET /profiles/\(UID.n(1))/share-candidates": (
                .ok, Fixtures.page([Self.candidate(2, "Sam", color: "#6B3A2E")])
            ),
        ])
        await model.load()
        let synced = try XCTUnwrap(synced)
        let home = model.households[0]
        let sam = model.profiles[0]
        let loaded = transport.sent.count

        await model.set(home, to: .read)
        XCTAssertEqual(model.access(home), .read)
        XCTAssertEqual(try synced.lastBody()?["householdId"] as? String, UID.n(7).description)
        XCTAssertEqual(try synced.lastBody()?["access"] as? String, "read")
        XCTAssertEqual(try synced.lastTouched(), ["playlist_household_share \(UID.n(3)) \(UID.n(7))"])
        await model.set(home, to: .write)
        XCTAssertEqual(model.access(home), .write)
        XCTAssertEqual(try synced.lastBody()?["access"] as? String, "write")
        await model.set(home, to: nil)
        XCTAssertNil(model.access(home))

        await model.set(sam, to: .read)
        XCTAssertEqual(model.access(sam), .read)
        XCTAssertEqual(try synced.lastBody()?["profileId"] as? String, UID.n(2).description)
        XCTAssertEqual(model.shares.map(\.name), ["Sam"])
        XCTAssertEqual(model.shares.map(\.color), ["#6B3A2E"])
        let local: [String] = try await synced.read(
            "SELECT access FROM playlist_share WHERE playlist_id = \(sqlID(3)) AND account_id = \(sqlID(2))")
        XCTAssertEqual(local, ["read"])
        await model.set(sam, to: .write)
        XCTAssertEqual(model.access(sam), .write)
        await model.set(sam, to: nil)
        XCTAssertNil(model.access(sam))
        XCTAssertEqual(model.profiles.map(\.name), ["Sam"], "still a candidate")

        let queued = try synced.queued()
        let path = "/profiles/\(UID.n(1))/playlists/\(UID.n(3))"
        XCTAssertEqual(
            queued,
            [
                "createPlaylistHouseholdShare POST \(path)/household-shares",
                "replacePlaylistHouseholdShare PUT \(path)/household-shares/\(UID.n(7))",
                "deletePlaylistHouseholdShare DELETE \(path)/household-shares/\(UID.n(7))",
                "createPlaylistShare POST \(path)/shares",
                "replacePlaylistShare PUT \(path)/shares/\(UID.n(2))",
                "deletePlaylistShare DELETE \(path)/shares/\(UID.n(2))",
            ])
        XCTAssertEqual(transport.sent.count, loaded, "nothing goes until the queue flushes")
        XCTAssertNil(model.error)
    }
}
