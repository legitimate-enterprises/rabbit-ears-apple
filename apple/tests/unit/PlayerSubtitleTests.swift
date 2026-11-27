import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

extension PlayerModelTests {
    func testNextSubtitlesStepsThroughTheMenuInOrder() async {
        serveSubtitles()
        await model.start()
        var seen: [PlayerModel.SubtitleChoice] = []
        for _ in 0..<5 {
            await model.nextSubtitles()
            seen.append(model.subtitleChoice)
        }
        XCTAssertEqual(seen, [.track(4), .track(5), .track(6), .off, .forcedOnly])
        await model.nextSubtitles(offeringTracks: false)
        XCTAssertEqual(model.subtitleChoice, .off, "without tracks it is Off and Forced only")
    }

    func testTheForcedTracksLateTextNeverReplacesATrackPickedMeanwhile() async throws {
        serveSubtitles()
        let gate = Gate()
        let model = PlayerModel(
            client: server.client(token: "t", transport: transport), endpoint: server, profileId: 2,
            item: Fixtures.decode(Fixtures.item(20, "movie", "Dune"), as: Item.self), output: output,
            capabilities: capabilities,
            fetchText: { url in
                if url.lastPathComponent == "4.vtt" { try await gate.wait() }
                return "WEBVTT\n\n00:00:01.000 --> 00:00:09.000\n\(url.lastPathComponent)\n"
            })
        let starting = Task { await model.start() }
        for _ in 0..<500 where model.stream == nil { try await Task.sleep(for: .milliseconds(2)) }
        await model.selectSubtitles(.track(5))
        XCTAssertEqual(model.cue(at: 2), "5.vtt")
        gate.open()
        await starting.value
        XCTAssertEqual(model.cue(at: 2), "5.vtt")
    }
}

extension OfflineBrowseTests {
    /// A file on the device shows only the sidecars downloaded with it,
    /// whatever else the server's file holds, online or not.
    func testAFileOnTheDeviceListsOnlyItsDownloadedSidecars() async throws {
        store.ledger.titles[20]?.subtitles = [
            StoredSubtitle(trackId: 5, language: "eng", title: "SDH", isForced: false, file: "20-5.vtt")
        ]
        let tracks = [5, 6].map { number in
            #"{"id":"\#(UID.n(number))","streamIndex":\#(number),"kind":"subtitle","codec":"subrip","#
                + #""language":"eng","isDefault":false,"isForced":false,"subtitleIsText":true}"#
        }
        harness.transport.routes["GET /media-files/\(UID.n(1))"] = (
            .ok,
            #"{"id":"\#(UID.n(1))","itemId":"\#(UID.n(20))","path":"/m/Dune.mkv","sizeBytes":1,"#
                + #""fileModifiedAt":"2026-01-01T00:00:00Z","createdAt":"2026-01-01T00:00:00Z","#
                + #""modifiedAt":"2026-01-01T00:00:00Z","chapters":[],"tracks":[\#(tracks.joined(separator: ","))]}"#
        )
        let item = Fixtures.decode(Fixtures.item(20, "movie", "Dune"), as: Item.self)
        for online in [true, false] {
            if !online { harness.goOffline() }
            let player = PlayerModel(
                client: harness.client, endpoint: harness.endpoint, profileId: 1, item: item, output: FakeOutput(),
                capabilities: FakeCapabilities(), fetchText: { _ in "" })
            await player.start(positionMs: 0)
            XCTAssertEqual(player.stream.map { URL(string: $0.streamUrl)?.isFileURL }, true)
            XCTAssertEqual(player.subtitleTracks.map(\.id), [5], online ? "online" : "offline")
            XCTAssertEqual(player.subtitleTracks.first?.title, "SDH")
        }
        XCTAssertFalse(harness.transport.paths(.get).contains("/media-files/\(UID.n(1))"), "the server is not asked")
    }
}
