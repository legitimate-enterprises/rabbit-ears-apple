import Foundation
import HTTPTypes
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// What happened first: claims sent and fetches started.
private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    var all: [String] { lock.withLock { log } }
    func add(_ event: String) { lock.withLock { log.append(event) } }
}

/// A request's titles are claimed together up front, so the server prepares them back to back without waiting
/// on the device, and each claim is kept until the server lets it go.
extension DownloadStoreTests {
    private var batches: [String] { harness.transport.paths(.post).filter { $0.hasSuffix("/downloads/batch") } }

    func testEveryTitleOfARequestIsClaimedInOneBatchBeforeTheFirstTransfer() async throws {
        let events = Events()
        let answer = harness.transport.respond
        harness.transport.respond = { sent in
            if sent.path.hasSuffix("/downloads/batch") { events.add("claim") }
            return answer?(sent)
        }
        harness.downloader.onFetch = { _ in events.add("fetch") }
        harness.resolves["item/\(UID.n(50))"] = (1...3).map { Fixtures.downloadTitle(UID.n($0), "song") }
        try await harness.download(.album(50))

        XCTAssertEqual(events.all.first, "claim")
        XCTAssertEqual(events.all.filter { $0 == "claim" }.count, 1)
        let claimed =
            harness.transport.json(.post, "/profiles/\(UID.n(1))/downloads/batch")?["titles"] as? [[String: Any]]
        XCTAssertEqual(
            claimed?.compactMap { ($0["itemId"] as? String).flatMap(UID.init) }, [1, 2, 3], "in download order")
        for id in (1...3).map(UID.n) { XCTAssertEqual(store.titles[id]?.state, .onDevice) }
    }

    /// Nothing reports the conversion's progress while the server holds the request, so no share is shown.
    func testATitleWaitingOnTheServerShowsPreparingUntilBytesArriveThenItsOwnProgress() async throws {
        let steps = Events()
        harness.downloader.onFetch = { progress in
            while !steps.all.contains("bytes") { try? await Task.sleep(for: .milliseconds(2)) }
            progress(0.25)
            while !steps.all.contains("done") { try? await Task.sleep(for: .milliseconds(2)) }
        }
        harness.resolves["item/\(UID.n(20))"] = [Fixtures.downloadTitle(20, "movie")]
        let downloading = Task { try await harness.download(.title(20)) }
        for _ in 0..<500 where harness.downloader.requests.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(store.titles[20]?.state.label, "Preparing")
        XCTAssertEqual(store.state(try XCTUnwrap(store.request(.title(20), profile: 1))), "0 of 1 · Preparing")

        steps.add("bytes")
        for _ in 0..<500 where store.titles[20]?.state == .preparing(0) { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(store.titles[20]?.state.label, "Downloading 25%")
        steps.add("done")
        try await downloading.value
        XCTAssertEqual(store.titles[20]?.state, .onDevice)
        XCTAssertEqual(DownloadState.preparing(0.4).label, "Preparing", "a stored share is never shown")
    }

    func testATitleTheBatchRefusesFailsAloneWithTheWordingOfASingleClaim() async throws {
        harness.refusing = [2: Fixtures.error("conflict", "no file"), 3: Fixtures.error("bad_request", "Not a title")]
        harness.resolves["item/\(UID.n(50))"] = (1...4).map { Fixtures.downloadTitle(UID.n($0), "song") }
        try await harness.download(.album(50))
        XCTAssertEqual(store.titles[1]?.state, .onDevice)
        XCTAssertEqual(store.titles[2]?.state, .failed("Nothing this device can keep"))
        XCTAssertEqual(store.titles[3]?.state, .failed("Not a title"))
        XCTAssertEqual(store.titles[4]?.state, .onDevice)
    }

    func testAClaimTheServerLostIsMadeAgainOnceThenTheTitleFails() async throws {
        harness.downloader.failure = .status(404)
        harness.resolves["item/\(UID.n(20))"] = [Fixtures.downloadTitle(20, "movie")]
        try await harness.download(.title(20))
        XCTAssertEqual(batches.count, 2)
        XCTAssertEqual(harness.downloader.requests.count, 2)
        XCTAssertEqual(store.titles[20]?.state, .failed("The server answered 404"))
    }

    func testRemovingARequestReleasesItsUnfetchedClaims() async throws {
        harness.downloader.failure = .interrupted(resumeData: nil)
        harness.resolves["item/\(UID.n(20))"] = [Fixtures.downloadTitle(20, "movie")]
        try await harness.download(.title(20))
        XCTAssertTrue(harness.transport.paths(.delete).isEmpty)
        store.remove(.title(20), profile: 1)
        for _ in 0..<500 where harness.transport.paths(.delete).isEmpty {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(harness.transport.paths(.delete), ["/profiles/\(UID.n(1))/downloads/\(UID.n(20))"])
    }

    func testARelaunchFetchesWithTheClaimItKeptAndClaimsNothingAgain() async throws {
        harness.downloader.failure = .interrupted(resumeData: nil)
        harness.resolves["item/\(UID.n(20))"] = [Fixtures.downloadTitle(20, "movie")]
        try await harness.download(.title(20))
        XCTAssertEqual(batches.count, 1)
        // The process that claimed it ends.
        store.link = nil
        await harness.settle()

        let downloader = FakeDownloader()
        let box = harness.box
        let reopened = DownloadStore(
            directory: harness.directory, downloader: downloader, facts: { box.facts }, pollInterval: .milliseconds(1))
        reopened.connect(client: harness.client, endpoint: harness.endpoint, token: "tok-1")
        await reopened.pump()
        XCTAssertEqual(batches.count, 1)
        let files = downloader.requests.compactMap { $0.url?.path() }.filter { $0.hasSuffix("/file") }
        XCTAssertEqual(files, ["/api/v2/downloads/\(UID.n(20))/file"])
        XCTAssertEqual(reopened.titles[20]?.state, .onDevice)
    }

    /// The ledger the version before claims were kept wrote: the title claims again.
    func testALedgerWithoutClaimsKeepsEveryDownloadAndClaimsWhatIsLeft() async throws {
        harness.resolves["item/\(UID.n(20))"] = [Fixtures.downloadTitle(20, "movie")]
        harness.resolves["item/\(UID.n(21))"] = [Fixtures.downloadTitle(21, "movie")]
        try await harness.download(.title(20))
        harness.downloader.failure = .interrupted(resumeData: nil)
        try await harness.download(.title(21))
        store.link = nil
        await harness.settle()
        func older(_ value: Any) -> Any {
            if let object = value as? [String: Any] { return object.filter { $0.key != "claim" }.mapValues(older) }
            return (value as? [Any])?.map(older) ?? value
        }
        let written = try Data(contentsOf: store.ledgerFile)
        XCTAssertTrue((String(bytes: written, encoding: .utf8) ?? "").contains(#""claim""#))
        let stripped = try JSONSerialization.data(withJSONObject: older(JSONSerialization.jsonObject(with: written)))
        XCTAssertFalse((String(bytes: stripped, encoding: .utf8) ?? "").contains(#""claim""#))
        try stripped.write(to: store.ledgerFile)

        let box = harness.box
        let reopened = DownloadStore(
            directory: harness.directory, downloader: FakeDownloader(), facts: { box.facts },
            pollInterval: .milliseconds(1))
        XCTAssertEqual(reopened.titles[20]?.state, .onDevice)
        XCTAssertEqual(reopened.titles[21]?.state, .pending)
        reopened.connect(client: harness.client, endpoint: harness.endpoint, token: "tok-1")
        await reopened.pump()
        XCTAssertEqual(reopened.titles[21]?.state, .onDevice)
        XCTAssertEqual(batches.count, 3)
    }

    func testLowDataModeWaitsWhateverWiFiOnlySaysWhileTheServerPrepares() async throws {
        store.wifiOnly = false
        harness.box.path = PathFacts(constrained: true)
        harness.resolves["item/\(UID.n(20))"] = [Fixtures.downloadTitle(20, "movie")]
        try await harness.download(.title(20))
        XCTAssertEqual(store.titles[20]?.state, .waitingForLowData)
        XCTAssertEqual(store.titles[20]?.state.label, "Waiting: Low Data Mode is on")
        XCTAssertTrue(harness.downloader.requests.isEmpty)
        XCTAssertEqual(batches.count, 1)
        harness.box.path = PathFacts()
        for _ in 0..<500 where store.titles[20]?.state != .onDevice {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(store.titles[20]?.state, .onDevice)
        XCTAssertEqual(harness.downloader.requests.first?.allowsConstrainedNetworkAccess, false)
    }

    func testTheNetworkRuleWaitsInLowDataModeAndOnAMeteredPathWithWiFiOnly() {
        // Wi-Fi only, expensive, constrained: what waits.
        let cases: [([Bool], DownloadState?)] = [
            ([false, false, false], nil),
            ([false, true, false], nil),
            ([true, false, false], nil),
            ([true, true, false], .waitingForWiFi),
            ([false, false, true], .waitingForLowData),
            ([false, true, true], .waitingForLowData),
            ([true, false, true], .waitingForLowData),
            ([true, true, true], .waitingForLowData),
        ]
        for (path, wait) in cases {
            XCTAssertEqual(
                DownloadState.waiting(wifiOnly: path[0], expensive: path[1], constrained: path[2]), wait, "\(path)")
        }
    }
}
