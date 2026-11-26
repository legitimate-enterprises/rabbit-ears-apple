import XCTest

@testable import RabbitEarsKit

@MainActor
final class MusicGenresTests: XCTestCase {
    private static func library(_ id: Int, _ kind: String) -> String {
        #"{"id":\#(id),"name":"Library","kind":"\#(kind)","scanHour":3,"watchFiles":true,"folders":[],"#
            + #""stats":{"movies":0,"shows":0,"seasons":0,"episodes":0,"files":0,"bytes":0,"unmatched":0},"#
            + #""createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}"#
    }

    func testGenresComeFromMusicLibrariesOnly() async throws {
        let transport = RoutingTransport()
        transport.respond = { sent in
            switch (sent.path, sent.query) {
            case ("/libraries", _):
                (.ok, Fixtures.page([Self.library(3, "music"), Self.library(1, "movies")]))
            case ("/genres", let query) where query.contains("libraryId=3"):
                (.ok, Fixtures.page([#"{"id":6,"name":"Rock"}"#, #"{"id":5,"name":"Jazz"}"#]))
            default: nil
            }
        }
        let model = MusicModel(
            client: ServerEndpoint(userInput: "192.168.1.9")!.client(token: "t", transport: transport), profileId: 1)
        let genres = try await model.musicGenres()
        XCTAssertEqual(genres.map(\.name), ["Jazz", "Rock"])
        XCTAssertEqual(transport.queries(.get, "/genres").count, 1)
    }
}
