import Foundation
import HTTPTypes
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

@MainActor
final class DownloadStoreTests: XCTestCase {
    var harness: DownloadHarness!
    var store: DownloadStore { harness.store }

    override func setUp() async throws {
        harness = DownloadHarness()
    }

    func testOneCopyServesEveryRequestAndProfileUntilTheLastGoes() async throws {
        harness.resolves["item/\(UID.n(50))"] = [Fixtures.downloadTitle(5, "song"), Fixtures.downloadTitle(6, "song")]
        harness.resolves["playlist/\(UID.n(3))"] = [Fixtures.downloadTitle(5, "song")]
        try await harness.download(.album(50), profile: 1)
        try await harness.download(.playlist(3), profile: 2)

        let fetched = harness.downloader.requests.filter { $0.url?.path() == "/api/v2/downloads/\(UID.n(5))/file" }
        XCTAssertEqual(fetched.count, 1, "a title two requests cover is stored once")
        XCTAssertEqual(fetched.first?.value(forHTTPHeaderField: "Authorization"), "Bearer tok-1")
        XCTAssertEqual(fetched.first?.url?.query(), "wait=1", "the server holds the fetch until the file is ready")
        XCTAssertEqual(store.titles[5]?.subtitles.map(\.trackId), [4])
        XCTAssertNotNil(store.onDevice(5, profile: 2))
        XCTAssertNil(store.onDevice(6, profile: 2), "a profile sees only what its own requests cover")
        XCTAssertEqual(
            harness.transport.paths(.delete).sorted(),
            ["/profiles/\(UID.n(1))/downloads/\(UID.n(5))", "/profiles/\(UID.n(1))/downloads/\(UID.n(6))"])

        store.remove(.album(50), profile: 1)
        XCTAssertTrue(harness.exists(5))
        XCTAssertNil(store.titles[6])
        let file = try XCTUnwrap(store.titles[5].flatMap(store.file(of:)))
        store.remove(.playlist(3), profile: 2)
        XCTAssertNil(store.titles[5])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: file.path(percentEncoded: false)),
            "the last reference takes the file")
        XCTAssertFalse(store.hasDownloads)
    }

    func testTheStoreIsKeptAcrossLaunchesAndOutOfBackups() async throws {
        harness.resolves["item/\(UID.n(20))"] = [Fixtures.downloadTitle(20, "movie")]
        try await harness.download(.title(20))
        let reopened = DownloadStore(
            directory: harness.directory, downloader: FakeDownloader(), facts: { fatalError() })
        XCTAssertEqual(reopened.titles[20]?.state, .onDevice)
        XCTAssertEqual(reopened.requests.map(\.target), [.title(20)])
        let values = try harness.directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testATitleMidFetchWhenTheAppStoppedWaitsAgainAtLaunch() async throws {
        harness.resolves["item/\(UID.n(20))"] = [Fixtures.downloadTitle(20, "movie")]
        harness.resolves["item/\(UID.n(21))"] = [Fixtures.downloadTitle(21, "movie")]
        try await harness.download(.title(20))
        try await harness.download(.title(21))
        store.ledger.titles[20]?.state = .downloading(0.4)
        store.ledger.titles[21]?.state = .preparing(0.1)
        store.save()
        let reopened = DownloadStore(
            directory: harness.directory, downloader: FakeDownloader(), facts: { fatalError() })
        XCTAssertEqual(reopened.titles[20]?.state, .pending)
        XCTAssertEqual(reopened.titles[21]?.state, .pending)
    }

    func testAStandingRequestTakesWhatArrivesAndDropsWhatLeaves() async throws {
        harness.resolves["item/\(UID.n(10))"] = [
            Fixtures.downloadTitle(101, "episode"), Fixtures.downloadTitle(102, "episode"),
        ]
        try await harness.download(.show(10))
        XCTAssertTrue(harness.exists(101))

        harness.resolves["item/\(UID.n(10))"] = [
            Fixtures.downloadTitle(102, "episode"), Fixtures.downloadTitle(103, "episode"),
        ]
        await store.sync(profile: 1)
        XCTAssertEqual(store.request(.show(10), profile: 1)?.titles, [102, 103])
        XCTAssertNil(store.titles[101])
        XCTAssertFalse(harness.exists(101))
        XCTAssertEqual(store.titles[103]?.state, .onDevice)
    }

    func testSyncRemovesWhatTheProfileMayNoLongerSee() async throws {
        harness.resolves["item/\(UID.n(20))"] = [Fixtures.downloadTitle(20, "movie")]
        harness.resolves["item/\(UID.n(21))"] = [Fixtures.downloadTitle(21, "movie")]
        try await harness.download(.title(20))
        try await harness.download(.title(21))
        harness.removing = [21]
        await store.sync(profile: 1)
        XCTAssertNil(store.titles[21])
        XCTAssertNotNil(store.titles[20])
        XCTAssertEqual(
            harness.transport.json(.post, "/profiles/\(UID.n(1))/downloads/sync")?["itemIds"] as? [String],
            [UID.n(20), UID.n(21)].map(\.description))
    }

    func testAProfileTheServerForgetsLosesItsDownloadsAndARevokedDeviceAll() async throws {
        harness.resolves["item/\(UID.n(20))"] = [Fixtures.downloadTitle(20, "movie")]
        try await harness.download(.title(20), profile: 1)
        try await harness.download(.title(20), profile: 2)
        harness.transport.routes["POST /profiles/\(UID.n(2))/downloads/sync"] = (.notFound, Fixtures.error("not_found"))
        let answer = harness.transport.respond
        harness.transport.respond = { $0.path == "/profiles/\(UID.n(2))/downloads/sync" ? nil : answer?($0) }
        await store.sync(profile: 2)
        XCTAssertTrue(store.requests(for: 2).isEmpty)
        XCTAssertTrue(harness.exists(20), "profile 1 still holds it")

        harness.transport.respond = { _ in (.unauthorized, Fixtures.error("unauthorized")) }
        await store.sync(profile: 1)
        XCTAssertFalse(store.hasDownloads)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: harness.directory.appending(path: "media").path(percentEncoded: false)))
    }

    /// A proxy or auth layer in front of the server may answer 401 with a body of its own.
    func testA401TheServerDidNotSendKeepsEveryDownload() async throws {
        let proxied: (HTTPResponse.Status, String) = (.unauthorized, "<html>401 Authorization Required</html>")
        harness.resolves["item/\(UID.n(20))"] = [Fixtures.downloadTitle(20, "movie")]
        harness.resolves["item/\(UID.n(21))"] = [Fixtures.downloadTitle(21, "movie")]
        try await harness.download(.title(20))

        let answer = harness.transport.respond
        harness.transport.respond = {
            $0.method == .post && $0.path == "/profiles/\(UID.n(1))/downloads/batch" ? proxied : answer?($0)
        }
        try await harness.download(.title(21))
        XCTAssertEqual(store.titles[21]?.state, .pending)

        harness.transport.respond = answer
        harness.downloader.failure = .status(401)
        await harness.settle()
        XCTAssertEqual(store.titles[21]?.state, .pending)

        harness.transport.respond = { _ in proxied }
        await store.sync(profile: 1)
        XCTAssertTrue(store.hasDownloads)
        XCTAssertTrue(harness.exists(20))
    }

    func testAProfileTheHouseholdNoLongerListsLosesItsDownloadsWhenTheOwnersMeSaysSo() async throws {
        for id in [20, 21, 22] { harness.resolves["item/\(UID.n(id))"] = [Fixtures.downloadTitle(UID.n(id), "movie")] }
        try await harness.download(.title(20), profile: 1)
        try await harness.download(.title(22), profile: 2)
        try await harness.download(.title(20), profile: 3)
        try await harness.download(.title(21), profile: 3)

        // Pending adults are listed to the owner alone, so another profile's answer leaves 3 be.
        try harness.keep(
            me: Fixtures.me.replacingOccurrences(
                of: #""activeProfileId":"\#(UID.n(1))""#, with: #""activeProfileId":"\#(UID.n(2))""#))
        await store.sync(profile: 2)
        XCTAssertEqual(store.requests(for: 3).count, 2)
        let file = try XCTUnwrap(store.titles[21].flatMap(store.file(of:)))

        try harness.keep(me: Fixtures.me)
        await store.sync(profile: 1)
        XCTAssertTrue(store.requests(for: 3).isEmpty)
        XCTAssertNil(store.titles[21])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
        XCTAssertTrue(harness.exists(20), "profile 1 still holds it")
        XCTAssertEqual(store.requests(for: 1).map(\.target), [.title(20)])
        XCTAssertEqual(store.requests(for: 2).map(\.target), [.title(22)])
        XCTAssertTrue(harness.exists(22))
    }

    func testWatchedTitlesLeaveStandingRequestsByEachLibrarysPolicy() async throws {
        // Two TV libraries: 2 removes once watched, as TV does by default; 7 is set to keep.
        var settings = store.settings(1)
        settings.keep[7] = true
        store.setSettings(settings, for: 1)
        harness.resolves["item/\(UID.n(10))"] = [
            Fixtures.downloadTitle(101, "episode", library: 2, watched: true),
            Fixtures.downloadTitle(102, "episode", library: 2),
        ]
        harness.resolves["item/\(UID.n(30))"] = [Fixtures.downloadTitle(301, "episode", library: 7, watched: true)]
        harness.resolves["collection/\(UID.n(4))"] = [Fixtures.downloadTitle(20, "movie", watched: true)]
        harness.resolves["item/\(UID.n(101))"] = [Fixtures.downloadTitle(101, "episode", library: 2, watched: true)]
        try await harness.download(.show(10))
        try await harness.download(.show(30))
        try await harness.download(.init(scope: .collection, id: 4, name: "Dune", standing: true))
        XCTAssertEqual(store.request(.show(10), profile: 1)?.titles, [102])
        XCTAssertEqual(store.request(.show(30), profile: 1)?.titles, [301])
        XCTAssertNotNil(store.titles[20], "movies keep watched titles")

        try await harness.download(.title(101))
        XCTAssertEqual(store.request(.title(101), profile: 1)?.titles, [101], "a title asked for itself stays")

        try await harness.replica.write { try $0.watch(102, for: 1, watched: true) }
        await store.applyKeepPolicy(1)
        XCTAssertEqual(store.request(.show(10), profile: 1)?.titles, [])
        XCTAssertNil(store.titles[102])
        XCTAssertFalse(harness.exists(102))
    }

    func testMusicAlwaysKeepsAndTheDefaultsFollowTheLibraryKind() {
        let settings = DownloadSettings()
        XCTAssertTrue(settings.keeps(library: 1, kind: .movie))
        XCTAssertFalse(settings.keeps(library: 1, kind: .episode))
        XCTAssertFalse(settings.keeps(library: 1, kind: .video))
        XCTAssertTrue(settings.keeps(library: 1, kind: .song))
        var never = settings
        never.keep[3] = false
        XCTAssertTrue(never.keeps(library: 3, kind: .song))
    }

    func testABigRequestAsksFirstUntilDontAskAgain() async throws {
        harness.resolves["item/\(UID.n(10))"] = (1...51).map {
            Fixtures.downloadTitle(UID.n(1000 + $0), "episode", size: 1)
        }
        let plan = try await harness.download(.show(10))
        XCTAssertEqual(plan?.count, 51)
        XCTAssertNil(store.request(.show(10), profile: 1), "nothing is kept until confirmed")

        store.allowanceBytes = 1000
        harness.resolves["item/\(UID.n(30))"] = [Fixtures.downloadTitle(301, "episode", size: 201)]
        let large = try await harness.download(.show(30))
        XCTAssertEqual(large?.sizeBytes, 201, "over a fifth of the allowance asks too")
        harness.resolves["item/\(UID.n(31))"] = [Fixtures.downloadTitle(311, "episode", size: 200)]
        let fifth = try await harness.download(.show(31))
        XCTAssertNil(fifth)

        store.keep(try XCTUnwrap(plan), dontAskAgain: true)
        XCTAssertEqual(store.request(.show(10), profile: 1)?.titles.count, 51)
        let again = try await harness.download(.show(30))
        XCTAssertNil(again, "Don't ask again stops the question for the profile")
        harness.resolves["item/\(UID.n(40))"] = harness.resolves["item/\(UID.n(10))"]
        let other = try await harness.download(.show(40), profile: 2)
        XCTAssertNotNil(other, "another profile is still asked")
    }

    func testTitlesPastTheAllowanceWaitAndASmallerOneGoesFirst() async throws {
        store.allowanceBytes = 150
        var settings = store.settings(1)
        settings.confirmBig = false
        store.setSettings(settings, for: 1)
        harness.resolves["item/\(UID.n(10))"] = [
            Fixtures.downloadTitle(101, "episode", size: 100), Fixtures.downloadTitle(102, "episode", size: 100),
            Fixtures.downloadTitle(103, "episode", size: 40),
        ]
        try await harness.download(.show(10))
        XCTAssertEqual(store.titles[101]?.state, .onDevice)
        XCTAssertEqual(store.titles[102]?.state, .waitingForSpace)
        XCTAssertEqual(store.titles[103]?.state, .onDevice)
        XCTAssertEqual(store.usedBytes, 140)

        store.allowanceBytes = 400
        await harness.settle()
        XCTAssertEqual(store.titles[102]?.state, .onDevice)
    }

    func testOffWiFiEveryTitleWaitsUnlessWiFiOnlyIsOff() async throws {
        harness.box.path = PathFacts(expensive: true)
        harness.resolves["item/\(UID.n(20))"] = [Fixtures.downloadTitle(20, "movie")]
        try await harness.download(.title(20))
        XCTAssertEqual(store.titles[20]?.state, .waitingForWiFi)
        XCTAssertTrue(harness.downloader.requests.isEmpty)
        XCTAssertEqual(
            harness.transport.paths(.post).filter { $0.hasSuffix("/batch") }.count, 1,
            "the server prepares the title while it waits")
        store.wifiOnly = false
        await harness.settle()
        XCTAssertEqual(store.titles[20]?.state, .onDevice)
        XCTAssertEqual(harness.downloader.requests.first?.allowsExpensiveNetworkAccess, true)
    }

    func testATitleWaitingForWiFiGoesWhenThePathChanges() async throws {
        harness.box.path = PathFacts(expensive: true)
        harness.resolves["item/\(UID.n(20))"] = [Fixtures.downloadTitle(20, "movie")]
        // Kept without keep(_:), whose own later pump would hide whether the path change pumps.
        let plan = try await store.plan(.title(20), quality: .original, profile: 1)
        store.apply(plan.titles, to: plan.target, profile: 1, quality: plan.quality)
        await store.pump()
        XCTAssertEqual(store.titles[20]?.state, .waitingForWiFi)
        harness.box.path = PathFacts()
        for _ in 0..<500 where store.titles[20]?.state != .onDevice {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(store.titles[20]?.state, .onDevice)
    }

    func testAnInterruptedFetchResumesWhereItStopped() async throws {
        harness.downloader.failure = .interrupted(resumeData: Data("half".utf8))
        harness.resolves["item/\(UID.n(20))"] = [Fixtures.downloadTitle(20, "movie")]
        try await harness.download(.title(20))
        XCTAssertEqual(store.titles[20]?.state, .pending)
        harness.downloader.failure = nil
        await harness.settle()
        XCTAssertEqual(store.titles[20]?.state, .onDevice)
        XCTAssertEqual(harness.downloader.resumes.dropFirst().first, Data("half".utf8))
    }

    func testAConversionTheServerFailsFailsTheTitleWithItsMessageAndARetryGoes() async throws {
        harness.downloader.failure = .status(500, message: "ffmpeg found no audio")
        harness.resolves["item/\(UID.n(20))"] = [Fixtures.downloadTitle(20, "movie")]
        try await harness.download(.title(20))
        XCTAssertEqual(store.titles[20]?.state, .failed("ffmpeg found no audio"))
        harness.downloader.failure = nil
        store.retry(20)
        await harness.settle()
        XCTAssertEqual(store.titles[20]?.state, .onDevice)
    }

    func testSigningOutDeletesEveryDownload() async throws {
        harness.resolves["item/\(UID.n(20))"] = [Fixtures.downloadTitle(20, "movie")]
        try await harness.download(.title(20))
        let credentials = MemoryCredentialStore()
        credentials.server = harness.endpoint.baseURL
        credentials.token = "tok-1"
        harness.transport.routes["GET /me"] = (.ok, Fixtures.me)
        harness.transport.routes["POST /me/lock"] = (.noContent, "")
        let app = AppModel(
            store: credentials, deviceName: "Mac", transport: harness.transport, downloads: harness.store,
            replicaDirectory: Fixtures.replicas)
        await app.restore()
        XCTAssertTrue(store.hasDownloads)
        await app.signOut()
        XCTAssertFalse(store.hasDownloads)
        XCTAssertEqual(harness.downloader.cancels, 1, "no transfer lands a file after sign-out")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: harness.directory.appending(path: "media").path(percentEncoded: false)))
    }

    func testASignInOnAnotherServerStartsEmpty() async throws {
        harness.resolves["item/\(UID.n(20))"] = [Fixtures.downloadTitle(20, "movie")]
        try await harness.download(.title(20))
        let other = ServerEndpoint(baseURL: URL(string: "http://other.local:8477")!)
        store.connect(client: other.client(token: "t", transport: harness.transport), endpoint: other, token: "t")
        XCTAssertFalse(store.hasDownloads)
    }
}

extension DownloadStoreTests {
    func testRestoringPastA401TheServerDidNotSendKeepsTheSessionAndEveryDownload() async throws {
        harness.resolves["item/\(UID.n(20))"] = [Fixtures.downloadTitle(20, "movie")]
        try await harness.download(.title(20))
        let credentials = MemoryCredentialStore()
        credentials.server = harness.endpoint.baseURL
        credentials.token = "tok-1"
        harness.transport.routes["GET /me"] = (.unauthorized, "<html>401 Authorization Required</html>")
        let app = AppModel(
            store: credentials, deviceName: "Mac", transport: harness.transport, downloads: harness.store,
            replicaDirectory: Fixtures.replicas)
        await app.restore()
        XCTAssertEqual(app.phase, .unreachable)
        XCTAssertEqual(credentials.token, "tok-1")
        XCTAssertTrue(store.hasDownloads)
        XCTAssertTrue(harness.exists(20))
    }

    /// The background session finishes a transfer after the process that started it is gone.
    func testAFileThatLandedWithItsSizeIsKeptAndOneOfAnotherSizeFetchedAgain() async throws {
        func fetches(_ id: UID) -> Int {
            harness.downloader.requests.filter { $0.url?.path() == "/api/v2/downloads/\(id)/file" }.count
        }
        harness.downloader.failure = .interrupted(resumeData: nil)
        harness.resolves["item/\(UID.n(20))"] = [Fixtures.downloadTitle(20, "movie")]
        harness.resolves["item/\(UID.n(21))"] = [Fixtures.downloadTitle(21, "movie")]
        try await harness.download(.title(20))
        try await harness.download(.title(21))
        let media = harness.directory.appending(path: "media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try Data(count: 100).write(to: media.appending(path: "\(UID.n(20)).mp4"))
        try Data(count: 7).write(to: media.appending(path: "\(UID.n(21)).mp4"))
        let tried = (fetches(20), fetches(21))

        harness.downloader.failure = nil
        await harness.settle()
        XCTAssertEqual(store.titles[20]?.state, .onDevice)
        XCTAssertEqual(fetches(20), tried.0, "the landed file is not fetched again")
        XCTAssertEqual(try Data(contentsOf: media.appending(path: "\(UID.n(20)).mp4")).count, 100)
        XCTAssertEqual(store.titles[21]?.state, .onDevice)
        XCTAssertEqual(fetches(21), tried.1 + 1)
    }
}
