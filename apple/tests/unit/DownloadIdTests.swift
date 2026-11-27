import Foundation
import HTTPTypes
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// Ids are UIDs on disk and in calls; what an earlier version kept by number is dropped.
extension DownloadStoreTests {
    func testCollectingRemovesAMediaFileNoTitleHolds() async throws {
        harness.resolves["item/\(UID.n(20))"] = [Fixtures.downloadTitle(20, "movie")]
        harness.resolves["item/\(UID.n(22))"] = [Fixtures.downloadTitle(22, "movie")]
        try await harness.download(.title(20))
        harness.downloader.failure = .interrupted(resumeData: nil)
        try await harness.download(.title(22))
        let media = harness.directory.appending(path: "media")
        // Numeric names are a v1 ledger's: stale, even where the number is a title held now.
        let orphans = ["\(UID.n(21)).mp4", "\(UID.n(21))-\(UID.n(4)).vtt", "20.mp4", "21-4.vtt"].map {
            media.appending(path: $0)
        }
        for file in orphans { try Data("media".utf8).write(to: file) }
        let landed = media.appending(path: "\(UID.n(22)).mp4")
        try Data("media".utf8).write(to: landed)

        store.collect()
        for file in orphans { XCTAssertFalse(FileManager.default.fileExists(atPath: file.path(percentEncoded: false))) }
        XCTAssertTrue(harness.exists(20))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: media.appending(path: "\(UID.n(20))-\(UID.n(4)).vtt").path(percentEncoded: false)))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: landed.path(percentEncoded: false)),
            "a title still held keeps what landed for it before it names it")
    }

    func testTheLedgerKeepsItsIdKeysAcrossLaunches() async throws {
        var settings = store.settings(2)
        settings.keep[7] = true
        store.setSettings(settings, for: 2)
        harness.resolves["item/\(UID.n(20))"] = [Fixtures.downloadTitle(20, "movie", library: 7)]
        try await harness.download(.title(20))
        let written = String(bytes: try Data(contentsOf: store.ledgerFile), encoding: .utf8) ?? ""
        XCTAssertTrue(written.contains(#""\#(UID.n(20))":{"#), "titles are keyed by the id's string")

        let reopened = DownloadStore(
            directory: harness.directory, downloader: FakeDownloader(), facts: { fatalError() })
        XCTAssertEqual(reopened.settings(2).keep, [7: true])
        XCTAssertEqual(reopened.titles[20]?.state, .onDevice)
        XCTAssertEqual(reopened.titles[20]?.libraryId, 7)
        XCTAssertEqual(reopened.requests.first?.profileId, 1)
        XCTAssertEqual(reopened.requests.first?.titles, [20])
    }

    func testANumericLedgerLoadsEmptyAndWhatItKeptIsSwept() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "v1 ledger \(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let media = directory.appending(path: "media")
        let art = directory.appending(path: "art")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: art, withIntermediateDirectories: true)
        let files = [
            media.appending(path: "20.mp4"), media.appending(path: "20-4.vtt"), art.appending(path: "item-20-poster"),
        ]
        for file in files { try Data("media".utf8).write(to: file) }
        let v1 = #"""
            {"wifiOnly":false,"allowanceBytes":1000,
             "settings":{"1":{"preferLocal":true,"quality":"original","keep":{"3":true},"confirmBig":true}},
             "requests":[{"profileId":1,"target":{"scope":"item","id":20,"name":"Dune","standing":false,"music":false},
                          "quality":"original","titles":[20],"createdAt":"2026-01-01T00:00:00Z"}],
             "titles":{"20":{"itemId":20,"kind":"movie","libraryId":1,"quality":"original","sizeBytes":100,
                             "state":{"onDevice":{}},"file":"20.mp4","subtitles":[],"art":["item-20-poster"]}},
             "shelf":{"art":["item-20-poster"]}}
            """#
        try Data(v1.utf8).write(to: directory.appending(path: "ledger.json"))

        let store = DownloadStore(directory: directory, downloader: FakeDownloader(), facts: { fatalError() })
        XCTAssertFalse(store.hasDownloads)
        XCTAssertTrue(store.titles.isEmpty)
        XCTAssertEqual(store.settings(1).keep, [:])
        for file in files {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: file.path(percentEncoded: false)), file.lastPathComponent)
        }
    }

    func testALocalSessionIsAnsweredHereAndAServerOneGoesToTheServer() async throws {
        harness.resolves["item/\(UID.n(20))"] = [Fixtures.downloadTitle(20, "movie")]
        try await harness.download(.title(20))
        let snapshot = await harness.endpoint.snapshot(harness.box.facts, checkedWith: harness.client, maxBitrate: nil)
        let stream = try await harness.client.startPlayback(
            body: .json(.init(profileId: 1, itemId: 20, snapshot: snapshot))
        ).created.body.json
        XCTAssertNotNil(store.sessions[stream.sessionId], "played from the device")
        XCTAssertEqual(stream.mediaFileId, 1, "the kept download's file")
        _ = try await harness.client.reportPlaybackPosition(
            path: .init(sessionId: stream.sessionId), body: .json(.init(positionMs: 1000, paused: false))
        ).noContent
        _ = try await harness.client.endPlayback(
            path: .init(sessionId: stream.sessionId), query: .init(positionMs: 2000)
        )
        .noContent
        XCTAssertNil(store.sessions[stream.sessionId])
        XCTAssertFalse(harness.transport.sent.contains { $0.path.hasPrefix("/playback/") }, "the server hears of none")

        let server: UID = 77
        _ = try? await harness.client.reportPlaybackPosition(
            path: .init(sessionId: server), body: .json(.init(positionMs: 1000, paused: false)))
        XCTAssertEqual(
            harness.transport.paths(.put).filter { $0.hasPrefix("/playback/") },
            ["/playback/sessions/\(server)/position"])
    }

    func testACallReadsOnlyAUIDAsAnId() {
        let id = UID.n(12)
        XCTAssertEqual(
            LocalCall(operation: "getItemArtwork", path: "/items/\(id)/artwork/poster", body: nil).id(after: "items"),
            id)
        for path in ["/items/12/artwork/poster", "/items/\(id.description.uppercased())/artwork/poster", "/items"] {
            XCTAssertNil(LocalCall(operation: "getItemArtwork", path: path, body: nil).id(after: "items"), path)
        }
        let key = ArtKey(id: id, kind: .backdrop, collection: true)
        XCTAssertEqual(key.file, "collection-\(id)-backdrop")
        XCTAssertEqual(ArtKey(file: key.file), key)
        XCTAssertNil(ArtKey(file: "item-12-poster"))
    }
}
