import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// With no connection, CarPlay browses and plays what the profile has downloaded.
@MainActor
final class CarPlayOfflineTests: XCTestCase {
    func testWithNoConnectionTheCarBrowsesTheProfilesDownloadedMusic() async throws {
        let adult: Account = Fixtures.decode(Fixtures.adult)
        XCTAssertEqual(
            CarPlayGate(phase: .browsing, profile: adult, online: false, reachable: true, downloadedMusic: true),
            .music(1))
        XCTAssertEqual(
            CarPlayGate(phase: .browsing, profile: adult, online: false, reachable: true, downloadedMusic: false),
            .offline)
        XCTAssertEqual(
            CarPlayGate(phase: .signedOut, profile: nil, online: false, reachable: true, downloadedMusic: true),
            .notSignedIn)

        let harness = DownloadHarness()
        harness.objects["GET /me"] = Fixtures.me
        harness.objects["GET /music/songs/\(UID.n(5))"] = Fixtures.song(5, "Reckoner", album: 50, track: 7)
        harness.objects["GET /music/albums/\(UID.n(50))"] = Fixtures.album(50, "In Rainbows")
        harness.objects["GET /music/artists/\(UID.n(40))"] = Fixtures.artist
        harness.resolves["item/\(UID.n(5))"] = [Fixtures.downloadTitle(5, "song", library: 3)]
        try await harness.download(.title(5))
        _ = try await harness.client.getMe()
        XCTAssertTrue(harness.store.hasMusic(for: 1))
        XCTAssertFalse(harness.store.hasMusic(for: 2), "another profile's downloads are not this one's")

        let fixture = ReplicaFixture()
        defer { fixture.remove() }
        let replica = try fixture.v1 { db in
            try db.account(1, "Avery")
            try db.artist(40, "Radiohead")
            try db.album(50, "In Rainbows", artist: 40)
            try db.song(5, "Reckoner", album: 50, track: 7)
        }
        harness.goOffline()
        let offline = CarPlayLibrary(
            music: MusicModel(client: harness.client, replica: replica, profileId: 1), stations: stationsModel(replica))
        let roomy = CarPlayLimits(maxItems: 500, maxSections: 50, limited: false)
        let albums = try await offline.albums(roomy)
        XCTAssertNil(albums.empty, "not No music yet")
        XCTAssertEqual(albums.sections.flatMap(\.rows).map(\.text), ["In Rainbows"])
        let artists = try await offline.artists(roomy)
        XCTAssertEqual(artists.sections.flatMap(\.rows).map(\.text), ["Radiohead"])
    }
}
