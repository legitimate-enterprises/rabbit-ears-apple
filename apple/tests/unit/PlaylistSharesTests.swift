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

    func testAKidGetsAPlaylistsViewOnlyForWhatIsSharedAndAddsToNone() async {
        let transport = RoutingTransport([
            "GET /profiles/2/playlists": (
                .ok, Fixtures.page([Fixtures.playlist(3, "Cartoons", kind: "movies", access: "read", ownerName: "Ann")])
            )
        ])
        let client = ServerEndpoint(userInput: "192.168.1.9")!.client(token: "t", transport: transport)
        let kid = PlaylistsModel(client: client, profileId: 2, adult: false)
        await kid.load()
        XCTAssertTrue(kid.offersView(.movies))
        XCTAssertFalse(kid.offersView(.music))
        XCTAssertEqual(kid.editable(.movies).map(\.id), [])

        transport.routes["GET /profiles/1/playlists"] = (
            .ok,
            Fixtures.page([
                Fixtures.playlist(3, "Theirs", kind: "movies", access: "read", ownerName: "Ann"),
                Fixtures.playlist(4, "Ours", kind: "movies", access: "write", ownerName: "Ann"),
                Fixtures.playlist(5, "Mine", kind: "movies"),
            ])
        )
        let adult = PlaylistsModel(client: client, profileId: 1)
        await adult.load()
        XCTAssertTrue(adult.offersView(.music))
        XCTAssertEqual(adult.editable(.movies).map(\.id), [4, 5])
    }

    private func model(_ routes: [String: (HTTPResponse.Status, String)]) -> (PlaylistSharesModel, RoutingTransport) {
        let transport = RoutingTransport(routes)
        let model = PlaylistSharesModel(
            client: ServerEndpoint(userInput: "192.168.1.9")!.client(token: "t", transport: transport),
            profileId: 1, playlistId: 3)
        return (model, transport)
    }

    private static func household(_ id: Int64, _ name: String, profiles: Int) -> String {
        #"{"id":\#(id),"name":"\#(name)","profiles":\#(profiles)}"#
    }

    private static func householdShare(_ id: Int64, _ name: String, access: String = "read") -> String {
        #"{"playlistId":3,"householdId":\#(id),"name":"\#(name)","access":"\#(access)","#
            + #""createdAt":"2026-01-01T00:00:00Z"}"#
    }

    /// In household 7, Home, unless told otherwise.
    private static func candidate(
        _ id: Int64, _ name: String, kind: String = "adult", household: Int64 = 7, householdName: String = "Home",
        color: String = "#2E6B5B"
    ) -> String {
        #"{"profileId":\#(id),"name":"\#(name)","kind":"\#(kind)","householdId":\#(household),"#
            + #""householdName":"\#(householdName)","color":"\#(color)"}"#
    }

    func testListsHouseholdsAndProfilesWithWhatEachMayDo() async {
        let (model, _) = model([
            "GET /profiles/1/share-households": (
                .ok,
                Fixtures.page([
                    Self.household(7, "Mark's household", profiles: 4),
                    Self.household(8, "Heidi's household", profiles: 1),
                ])
            ),
            "GET /profiles/1/playlists/3/household-shares": (
                .ok, Fixtures.page([Self.householdShare(7, "Mark's household")])
            ),
            "GET /profiles/1/playlists/3/shares": (
                .ok,
                Fixtures.page([
                    Fixtures.share(2, "Heidi", access: "write"),
                    Fixtures.share(9, "Gone", kind: "kid", household: 8),
                ])
            ),
            "GET /profiles/1/share-candidates": (
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

    func testOneHouseholdGoesUnnamed() async {
        let (model, _) = model([
            "GET /profiles/1/share-households": (.ok, Fixtures.page([Self.household(7, "Home", profiles: 3)])),
            "GET /profiles/1/playlists/3/household-shares": (.ok, Fixtures.page([])),
            "GET /profiles/1/playlists/3/shares": (.ok, Fixtures.page([])),
            "GET /profiles/1/share-candidates": (
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

    func testEachChangeCreatesReplacesOrDeletesAShare() async {
        let (model, transport) = model([
            "GET /profiles/1/share-households": (.ok, Fixtures.page([Self.household(7, "Home", profiles: 3)])),
            "GET /profiles/1/playlists/3/household-shares": (.ok, Fixtures.page([])),
            "GET /profiles/1/playlists/3/shares": (.ok, Fixtures.page([])),
            "GET /profiles/1/share-candidates": (.ok, Fixtures.page([Self.candidate(2, "Sam")])),
            "POST /profiles/1/playlists/3/household-shares": (.created, Self.householdShare(7, "Home")),
            "PUT /profiles/1/playlists/3/household-shares/7": (.ok, Self.householdShare(7, "Home", access: "write")),
            "DELETE /profiles/1/playlists/3/household-shares/7": (.noContent, ""),
            "POST /profiles/1/playlists/3/shares": (.created, Fixtures.share(2, "Sam")),
            "PUT /profiles/1/playlists/3/shares/2": (.ok, Fixtures.share(2, "Sam", access: "write")),
            "DELETE /profiles/1/playlists/3/shares/2": (.noContent, ""),
        ])
        await model.load()
        let home = model.households[0]
        let sam = model.profiles[0]

        transport.routes["GET /profiles/1/playlists/3/household-shares"] = (
            .ok, Fixtures.page([Self.householdShare(7, "Home")])
        )
        await model.set(home, to: .read)
        XCTAssertEqual(transport.json(.post, "/profiles/1/playlists/3/household-shares")?["householdId"] as? Int, 7)
        XCTAssertEqual(transport.json(.post, "/profiles/1/playlists/3/household-shares")?["access"] as? String, "read")
        XCTAssertEqual(model.access(home), .read)

        await model.set(home, to: .write)
        XCTAssertEqual(
            transport.json(.put, "/profiles/1/playlists/3/household-shares/7")?["access"] as? String, "write")
        await model.set(home, to: nil)
        XCTAssertEqual(transport.paths(.delete), ["/profiles/1/playlists/3/household-shares/7"])

        transport.routes["GET /profiles/1/playlists/3/shares"] = (.ok, Fixtures.page([Fixtures.share(2, "Sam")]))
        await model.set(sam, to: .read)
        XCTAssertEqual(transport.json(.post, "/profiles/1/playlists/3/shares")?["profileId"] as? Int, 2)
        XCTAssertEqual(model.access(sam), .read)
        await model.set(sam, to: .write)
        XCTAssertEqual(transport.json(.put, "/profiles/1/playlists/3/shares/2")?["access"] as? String, "write")
        await model.set(sam, to: nil)
        XCTAssertEqual(transport.paths(.delete).last, "/profiles/1/playlists/3/shares/2")
        XCTAssertNil(model.error)
    }

    func testAFailedChangeSaysWhyAndKeepsTheAccess() async {
        let (model, _) = model([
            "GET /profiles/1/share-households": (.ok, Fixtures.page([Self.household(7, "Home", profiles: 3)])),
            "GET /profiles/1/playlists/3/household-shares": (.ok, Fixtures.page([])),
            "GET /profiles/1/playlists/3/shares": (.ok, Fixtures.page([])),
            "GET /profiles/1/share-candidates": (.ok, Fixtures.page([])),
            "POST /profiles/1/playlists/3/household-shares": (.conflict, Fixtures.error("conflict", "Already shared.")),
        ])
        await model.load()
        XCTAssertTrue(model.profiles.isEmpty)
        await model.set(model.households[0], to: .write)
        XCTAssertNotNil(model.error)
        XCTAssertNil(model.access(model.households[0]))
    }
}
