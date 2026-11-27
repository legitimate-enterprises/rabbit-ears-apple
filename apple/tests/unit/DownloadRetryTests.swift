import Foundation
import HTTPTypes
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// A pump or sync that meets a server it cannot reach, or a proxy, keeps every download and tries again.
extension DownloadStoreTests {
    func testAPumpTheServerStoppedTriesAgainByItself() async throws {
        harness.downloader.failure = .interrupted(resumeData: nil)
        harness.resolves["item/\(UID.n(20))"] = [Fixtures.downloadTitle(20, "movie")]
        try await harness.download(.title(20))
        XCTAssertEqual(store.titles[20]?.state, .pending)
        harness.downloader.failure = nil
        for _ in 0..<500 where store.titles[20]?.state != .onDevice {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(store.titles[20]?.state, .onDevice)
    }

    /// A proxy in front of the server may answer 404 with a body of its own.
    func testA404TheServerDidNotSendKeepsTheProfilesRequestsAndDownloads() async throws {
        let proxied: (HTTPResponse.Status, String) = (.notFound, "<html>404 Not Found</html>")
        harness.resolves["item/\(UID.n(10))"] = [Fixtures.downloadTitle(101, "episode")]
        try await harness.download(.show(10))
        let answer = harness.transport.respond
        for path in ["/profiles/\(UID.n(1))/downloads/resolve", "/profiles/\(UID.n(1))/downloads/sync"] {
            harness.transport.respond = { $0.path == path ? proxied : answer?($0) }
            await store.sync(profile: 1)
            XCTAssertEqual(store.requests(for: 1).map(\.target), [.show(10)], path)
            XCTAssertTrue(harness.exists(101), path)
        }
    }
}
