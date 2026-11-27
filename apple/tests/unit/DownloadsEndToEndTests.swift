import AVFoundation
import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// Downloads a fixture movie from a real server through URLSession and
/// plays the kept file with AVPlayer, with the server then gone. Set
/// RABBIT_EARS_E2E_SERVER to a fresh server's address and
/// RABBIT_EARS_E2E_MOVIES to the fixtures' Movies folder (prefix both with
/// TEST_RUNNER_ under xcodebuild); without them it skips.
@MainActor
final class DownloadsEndToEndTests: XCTestCase {
    private var server: URL!
    private var token = ""

    private func call(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> Any? {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "api/v2\(path)", relativeTo: server)))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw APIError(status: status, code: ._internal, message: String(bytes: data, encoding: .utf8) ?? "")
        }
        return data.isEmpty ? nil : try JSONSerialization.jsonObject(with: data)
    }

    private func items(_ path: String) async throws -> [[String: Any]] {
        (try await call("GET", path) as? [String: Any])?["items"] as? [[String: Any]] ?? []
    }

    /// An admin, a Movies library over the fixtures, scanned: the movie to download.
    private func seed(movies: String) async throws -> UID {
        let account: [String: Any] = [
            "email": "ada@example.com", "password": "correct horse battery", "deviceName": "e2e", "platform": "macos",
        ]
        let health = try await call("GET", "/health") as? [String: Any]
        let signed =
            health?["setupRequired"] as? Bool == true
            ? try await call("POST", "/setup", account.merging(["serverName": "Den", "name": "Ada"]) { $1 })
            : try await call("POST", "/auth/sign-in", account)
        token = try XCTUnwrap((signed as? [String: Any])?["token"] as? String)
        var library = try await items("/libraries").first { $0["kind"] as? String == "movies" }
        if library == nil {
            library = try await call("POST", "/libraries", ["name": "Movies", "kind": "movies"]) as? [String: Any]
            _ = try await call("POST", "/libraries/\(library?["id"] ?? "")/folders", ["path": movies])
        }
        let libraryId = try XCTUnwrap(library?["id"] as? String)
        for _ in 0..<60 {
            if let scan = try await items("/tasks").first(where: { $0["kind"] as? String == "scan:\(libraryId)" }),
                scan["lastRun"] == nil
            {
                _ = try await call(
                    "PUT", "/tasks/\(scan["id"] ?? "")",
                    [
                        "name": scan["name"] ?? "", "kind": scan["kind"] ?? "",
                        "nextRunAt": ISO8601DateFormatter().string(from: Date()),
                    ])
            }
            let movie = try await items("/items?kind=movie").first { ($0["parsedTitle"] as? String) == "Toy Story" }
            if let id = (movie?["id"] as? String).flatMap(UID.init),
                try await !items("/media-files?itemId=\(id)").isEmpty
            {
                return id
            }
            try await Task.sleep(for: .seconds(2))
        }
        throw XCTSkip("the fixtures did not scan in time")
    }

    func testAMovieDownloadsAndPlaysWithTheServerGone() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["RABBIT_EARS_E2E_SERVER"], let movies = environment["RABBIT_EARS_E2E_MOVIES"]
        else { throw XCTSkip("RABBIT_EARS_E2E_SERVER and RABBIT_EARS_E2E_MOVIES are not set") }
        server = try XCTUnwrap(URL(string: address))
        let movieId = try await seed(movies: movies)

        let directory = FileManager.default.temporaryDirectory.appending(path: "e2e-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadStore(directory: directory, downloader: URLSessionDownloader(), facts: { .decoder })
        let endpoint = ServerEndpoint(baseURL: server)
        let client = endpoint.client(token: token, offline: store)
        let plays = PlayLog()
        store.connect(client: client, endpoint: endpoint, token: token, plays: plays.plays)
        let me = try await client.getMe().ok.body.json
        _ = try await client.unlockProfile(path: .init(profileId: me.account.id), body: .json(.init())).noContent

        let target = DownloadTarget(scope: .item, id: movieId, name: "Toy Story", standing: false)
        _ = try await store.request(target, quality: .original, profile: me.account.id)
        for _ in 0..<600 where store.titles[movieId]?.state != .onDevice {
            if case .failed(let reason) = store.titles[movieId]?.state { return XCTFail(reason) }
            await store.pump()
            try await Task.sleep(for: .milliseconds(200))
        }
        let title = try XCTUnwrap(store.onDevice(movieId, profile: me.account.id))
        let file = try XCTUnwrap(store.file(of: title))
        let size = try FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false))[.size] as? Int64
        XCTAssertEqual(size, title.sizeBytes)
        XCTAssertGreaterThan(title.sizeBytes, 1_000_000)

        // The server goes: every call now fails as with no network.
        let unreachable = RoutingTransport()
        unreachable.failure = URLError(.cannotConnectToHost)
        let offline = endpoint.client(token: token, transport: unreachable, offline: store)
        _ = try? await offline.getMe()
        let output = AVPlayerOutput()
        output.player.isMuted = true
        let item = Fixtures.decode(Fixtures.item(movieId, "movie", "Toy Story"), as: Item.self)
        let player = PlayerModel(
            client: offline, endpoint: endpoint, profileId: me.account.id, item: item, output: output,
            capabilities: FakeCapabilities())
        await player.start(positionMs: 0)
        XCTAssertEqual(player.stream?.streamUrl, file.absoluteString)
        XCTAssertNil(player.error)
        for _ in 0..<100 where output.positionMs < 1000 { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertGreaterThanOrEqual(output.positionMs, 1000, "the kept file plays")
        await player.stop()
        let saved = plays.calls.compactMap { call -> Int64? in
            guard case .progress(_, movieId, _, let position, _, _) = call else { return nil }
            return position
        }
        XCTAssertGreaterThan(saved.last ?? 0, 0)
    }
}
