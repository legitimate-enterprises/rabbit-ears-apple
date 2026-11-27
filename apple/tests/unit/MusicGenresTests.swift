import GRDB
import XCTest

@testable import RabbitEarsKit

@MainActor
final class MusicGenresTests: XCTestCase {
    func testGenresComeFromWhatTheProfileHearsInMusicLibrariesOnly() async throws {
        let fixture = ReplicaFixture()
        defer { fixture.remove() }
        let replica = try fixture.v1 { db in
            try db.account(1, "Avery")
            try db.account(3, "Kit", kind: "kid", movies: "PG", tv: "TV-Y")
            try db.library(1, "movies")
            try db.library(3, "music")
            try db.item(20, "movie", "Dune", rating: "PG-13", genres: [(4, "Drama")])
            try db.artist(40, "Radiohead")
            try db.album(50, "In Rainbows", artist: 40)
            try db.song(1, "Nude", album: 50)
            try db.song(2, "Swear", album: 50, explicit: true)
            try db.genre(6, "Rock", on: 50)
            try db.genre(5, "Jazz", on: 40)
            try db.genre(7, "Punk", on: 2)
        }
        let client = ServerEndpoint(userInput: "192.168.1.9")!.client(token: "t", transport: RoutingTransport())
        let adult = try await MusicModel(client: client, replica: replica, profileId: 1).musicGenres()
        XCTAssertEqual(adult.map(\.name), ["Jazz", "Punk", "Rock"])
        let kid = try await MusicModel(client: client, replica: replica, profileId: 3).musicGenres()
        XCTAssertEqual(kid.map(\.name), ["Jazz", "Rock"], "Punk is only on an explicit song")
    }
}
