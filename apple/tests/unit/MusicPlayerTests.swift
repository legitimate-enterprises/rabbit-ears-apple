import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

@MainActor
final class FakeAudioOutput: AudioOutput {
    var loaded: [URL] = []
    var seeks: [Int64] = []
    var stops = 0
    var positionMs: Int64 = 0
    var isPaused = true
    var isPlaying = false
    /// Play leaves it waiting, as AVPlayer does until it has media to play.
    var waits = false
    var onFailure: ((String) -> Void)?
    var onEnd: (() -> Void)?
    var onInterruption: ((AudioInterruption) -> Void)?
    var onPlayingChange: (() -> Void)?

    func load(_ url: URL) { loaded.append(url) }
    func play() {
        isPaused = false
        isPlaying = !waits
    }
    func pause() {
        isPaused = true
        isPlaying = false
    }
    func seek(toMs ms: Int64) { seeks.append(ms) }
    func stop() {
        stops += 1
        isPaused = true
        isPlaying = false
    }
}

@MainActor
final class FakeNowPlaying: NowPlayingCenter {
    var shown: [NowPlayingInfo?] = []
    var onCommand: ((RemoteCommand) -> Void)?
    func show(_ info: NowPlayingInfo?) { shown.append(info) }
}

extension Fixtures {
    /// A song's direct-play session; its id is the song's.
    static func audioStream(_ session: Int64, verdict: String = "direct_play", position: Int64 = 0) -> String {
        #"{"sessionId":\#(session),"entry":{"position":0,"verdict":"\#(verdict)","videoAction":"copy","#
            + #""audioAction":"copy","subtitleAction":"none","bad":false},"#
            + #""streamUrl":"/api/v1/streams/s\#(session)/0/file","mediaFileId":1,"streamKind":"file","#
            + #""positionMs":\#(position),"#
            + #""negotiated":{"verdict":"\#(verdict)","width":0,"height":0,"bitrate":900000,"#
            + #""audioCodec":"flac","lossless":true},"rungs":[],"sidecars":[]}"#
    }
}

@MainActor
final class MusicPlayerTests: XCTestCase {
    var transport: RoutingTransport!
    var output: FakeAudioOutput!
    var center: FakeNowPlaying!
    var player: MusicPlayer!
    var activations = 0
    /// Songs whose playback the server refuses, read off the main actor
    /// while each test awaits the request.
    nonisolated(unsafe) var refused: Set<Int64> = []
    /// Sessions the server has ended, as it does a song's when a video
    /// starts on the device; every request to one answers 404.
    nonisolated(unsafe) var gone: Set<String> = []

    override func setUp() async throws {
        transport = RoutingTransport()
        transport.respond = { [unowned self] sent in
            switch (sent.method, sent.path) {
            case (.post, "/playback/sessions"):
                let body = (try? JSONSerialization.jsonObject(with: Data(sent.body.utf8))) as? [String: Any]
                let item = (body?["itemId"] as? NSNumber)?.int64Value ?? 0
                let position = (body?["positionMs"] as? NSNumber)?.int64Value ?? 0
                return self.refused.contains(item)
                    ? (.conflict, Fixtures.error("conflict", "Nothing on the plan can play."))
                    : (.created, Fixtures.audioStream(item, position: position))
            case (.delete, let path), (.put, let path):
                return self.gone.contains(where: path.hasPrefix) ? nil : (.noContent, "")
            default: return nil
            }
        }
        output = FakeAudioOutput()
        center = FakeNowPlaying()
        let server = ServerEndpoint(userInput: "192.168.1.9")!
        player = MusicPlayer(
            client: server.client(token: "t", transport: transport), endpoint: server, profileId: 1, output: output,
            capabilities: FakeCapabilities(), activateSession: { [unowned self] in self.activations += 1 })
        player.attach(center)
    }

    private var started: [Int64] {
        transport.sent.filter { $0.method == .post && $0.path == "/playback/sessions" }.compactMap { sent in
            let body = (try? JSONSerialization.jsonObject(with: Data(sent.body.utf8))) as? [String: Any]
            return (body?["itemId"] as? NSNumber)?.int64Value
        }
    }

    private var ended: [String] { transport.paths(.delete) }

    func testTheAudioSessionWaitsForPlay() async {
        XCTAssertEqual(activations, 0)
        await player.play(Fixtures.songs(3), source: "In Rainbows", playlistId: 8)
        XCTAssertEqual(activations, 1)
        let body = transport.json(.post, "/playback/sessions")
        XCTAssertEqual(body?["itemId"] as? Int, 1)
        XCTAssertEqual(body?["positionMs"] as? Int, 0)
        XCTAssertEqual(body?["playlistId"] as? Int, 8)
        XCTAssertNotNil(body?["snapshot"])
        XCTAssertEqual(output.loaded.map(\.path), ["/api/v1/streams/s1/0/file"])
        XCTAssertTrue(player.playing)
        XCTAssertEqual(player.stream?.negotiated.verdict, .directPlay)
        let info = center.shown.last??.title
        XCTAssertEqual(info, "Song 1")
    }

    func testAnEndedSongEndsItsSessionAndTheQueuePlaysOn() async {
        await player.play(Fixtures.songs(2), source: "")
        output.positionMs = 240_000
        await player.songEnded()
        XCTAssertEqual(ended, ["/playback/sessions/1"])
        XCTAssertTrue(transport.queries(.delete, "/playback/sessions/1").contains("positionMs=240000"))
        XCTAssertEqual(player.current?.id, 2)
        await player.songEnded()
        XCTAssertEqual(ended, ["/playback/sessions/1", "/playback/sessions/2"])
        XCTAssertFalse(player.playing)
        XCTAssertNil(player.stream)
        XCTAssertNil(player.current, "the queue running out empties it, so the mini player goes")
        XCTAssertNil(center.shown.last ?? nil)
    }

    func testTheTenSecondReportCarriesThePosition() async throws {
        await player.play(Fixtures.songs(1), source: "")
        output.positionMs = 10_000
        await player.tick()
        XCTAssertEqual(transport.json(.put, "/playback/sessions/1/position")?["positionMs"] as? Int, 10_000)
        await player.pause()
        let paused = try XCTUnwrap(transport.json(.put, "/playback/sessions/1/position"))
        XCTAssertEqual(paused["paused"] as? Bool, true)
        XCTAssertEqual(center.shown.last??.playing, false)
    }

    func testAPickedSongThatCannotPlayAlertsAndTheSongPlayingCarriesOn() async {
        await player.play(Fixtures.songs(7), from: 3, source: "In Rainbows")
        refused = [7]
        let reckoner = player.queue.upNext.last!.id
        await player.jump(to: reckoner)
        XCTAssertEqual(player.alert, "\u{201C}Song 7\u{201D} can\u{2019}t be played")
        XCTAssertEqual(player.current?.id, 4)
        XCTAssertTrue(player.playing)
        XCTAssertEqual(ended, [])
        XCTAssertEqual(started, [4, 7])
    }

    func testAQueuedSongThatCannotPlayIsSkippedSilently() async {
        refused = [2]
        await player.play(Fixtures.songs(3), source: "")
        await player.songEnded()
        XCTAssertNil(player.alert)
        XCTAssertEqual(started, [1, 2, 3])
        XCTAssertEqual(player.current?.id, 3)
    }

    func testThreeQueuedFailuresInARowStopWithOneAlert() async {
        refused = [2, 3, 4]
        await player.play(Fixtures.songs(6), source: "")
        await player.songEnded()
        XCTAssertEqual(started, [1, 2, 3, 4])
        XCTAssertEqual(player.alert, "These songs can\u{2019}t be played")
        XCTAssertFalse(player.playing)
        XCTAssertNil(player.stream)
    }

    func testAPlayerFailureMovesDownThePlanThenSkipsWhenItIsExhausted() async {
        await player.play(Fixtures.songs(2), source: "")
        await player.songEnded()
        transport.routes["POST /playback/sessions/2/events"] = (
            .ok, #"{"action":"restart","stream":\#(Fixtures.audioStream(2, verdict: "audio_transcode"))}"#
        )
        await player.outputFailed("cannot decode")
        XCTAssertEqual(transport.json(.post, "/playback/sessions/2/events")?["kind"] as? String, "client_failure")
        XCTAssertEqual(output.loaded.count, 3)
        XCTAssertEqual(player.stream?.negotiated.verdict, .audioTranscode)
        transport.routes["POST /playback/sessions/2/events"] = (.conflict, Fixtures.error("conflict"))
        await player.outputFailed("cannot decode")
        XCTAssertNil(player.alert)
        XCTAssertEqual(ended.last, "/playback/sessions/2")
        XCTAssertFalse(player.playing)
    }

    func testPreviousRestartsPastThreeSecondsElseStepsBack() async {
        await player.play(Fixtures.songs(3), from: 1, source: "")
        output.positionMs = 45_000
        await player.previous()
        XCTAssertEqual(output.seeks, [0])
        XCTAssertEqual(player.current?.id, 2)
        output.positionMs = 1_000
        await player.previous()
        XCTAssertEqual(player.current?.id, 1)
        XCTAssertEqual(ended, ["/playback/sessions/2"])
    }

    func testRemoteCommandsDriveThePlayer() async throws {
        await player.play(Fixtures.songs(3), source: "")
        await player.handle(.next)
        XCTAssertEqual(player.current?.id, 2)
        await player.handle(.toggle)
        XCTAssertFalse(player.playing)
        await player.handle(.play)
        XCTAssertTrue(player.playing)
        await player.handle(.seek(ms: 60_000))
        XCTAssertEqual(output.seeks.last, 60_000)
        await player.handle(.repeatMode(.one))
        await player.handle(.shuffle(true))
        let info = try XCTUnwrap(center.shown.last ?? nil)
        XCTAssertEqual(info.repeatMode, .one)
        XCTAssertTrue(info.shuffled)
        XCTAssertEqual(info.artworkItemId, 50)
        XCTAssertNotNil(center.onCommand)
    }

    func testADetachedPlayerHearsNoCommandsAndShowsNothingUntilAttachedAgain() async throws {
        await player.play(Fixtures.songs(3), source: "")
        await player.pause()
        player.detach()
        XCTAssertNil(center.onCommand)
        XCTAssertNil(center.shown.last ?? nil)
        await player.tick()
        XCTAssertNil(center.shown.last ?? nil)
        XCTAssertFalse(player.playing)
        player.attach(center)
        let info = try XCTUnwrap(center.shown.last ?? nil)
        XCTAssertEqual(info.title, "Song 1")
        XCTAssertFalse(info.playing)
        center.onCommand?(.play)
        for _ in 0..<100 where !player.playing { await Task.yield() }
        XCTAssertTrue(player.playing)
        XCTAssertEqual(player.queue.entries.count, 3)
    }

    func testTheQueueRunningOutLeavesNothingToResume() async {
        await player.play(Fixtures.songs(1), source: "")
        await player.songEnded()
        XCTAssertTrue(player.queue.entries.isEmpty)
        await player.resume()
        XCTAssertEqual(started, [1])
        XCTAssertFalse(player.playing)
    }

    func testNextPastTheLastSongEndsTheQueue() async {
        await player.play(Fixtures.songs(1), source: "")
        await player.next()
        XCTAssertNil(player.current)
        XCTAssertEqual(ended, ["/playback/sessions/1"])
        XCTAssertNil(center.shown.last ?? nil)
    }

    func testResumeOntoASessionTheServerEndedStartsANewOneAtThePosition() async {
        await player.play(Fixtures.songs(2), source: "")
        output.positionMs = 61_000
        await player.pause()
        gone = ["/playback/sessions/1"]
        await player.resume()
        XCTAssertEqual(started, [1, 1])
        XCTAssertEqual(transport.json(.post, "/playback/sessions")?["positionMs"] as? Int, 61_000)
        XCTAssertEqual(output.loaded.count, 2)
        XCTAssertEqual(output.seeks, [61_000])
        XCTAssertTrue(player.playing)
        XCTAssertEqual(player.queue.upNext.map(\.song.id), [2], "the queue is kept")
        XCTAssertNil(player.alert)
    }

    func testResumeOntoALiveSessionPlaysOn() async {
        await player.play(Fixtures.songs(1), source: "")
        await player.pause()
        await player.resume()
        XCTAssertEqual(started, [1])
        XCTAssertEqual(output.loaded.count, 1)
        XCTAssertTrue(player.playing)
    }

    func testAStopWhileTheNextSongStartsLeavesNothingPlaying() async {
        await player.play(Fixtures.songs(2), source: "")
        let arrived = expectation(description: "the old session's end is in flight")
        let release = DispatchSemaphore(value: 0)
        let old = transport.respond
        transport.respond = { sent in
            if sent.method == .delete && sent.path == "/playback/sessions/1" {
                arrived.fulfill()
                release.wait()
            }
            return old?(sent)
        }
        let next = Task { await player.next() }
        await fulfillment(of: [arrived], timeout: 5)
        await player.stop()
        release.signal()
        await next.value
        XCTAssertFalse(player.playing)
        XCTAssertNil(player.stream)
        XCTAssertEqual(output.loaded.count, 1)
        XCTAssertEqual(Set(ended), ["/playback/sessions/1", "/playback/sessions/2"])
    }

    /// Skips to the next song and makes `edit` while its session is being opened.
    private func whileTheNextSongStarts(_ edit: () -> Void) async {
        let arrived = expectation(description: "the next song's start is in flight")
        let release = DispatchSemaphore(value: 0)
        let old = transport.respond
        transport.respond = { sent in
            if sent.method == .post {
                arrived.fulfill()
                release.wait()
            }
            return old?(sent)
        }
        let next = Task { await player.next() }
        await fulfillment(of: [arrived], timeout: 5)
        edit()
        release.signal()
        await next.value
    }

    func testAQueueEditWhileTheNextSongStartsIsKept() async {
        await player.play(Fixtures.songs(4), source: "")
        await whileTheNextSongStarts { player.removeFromUpNext(3) }
        XCTAssertEqual(player.current?.id, 2)
        XCTAssertEqual(player.queue.entries.map(\.song.id), [1, 2, 3])
    }

    func testShuffleWhileASongStartsShufflesAroundIt() async {
        player.shuffleOrder = { $0.sorted { $0.song.id > $1.song.id } }
        await player.play(Fixtures.songs(4), source: "")
        await whileTheNextSongStarts { player.setShuffle(true) }
        XCTAssertEqual(player.current?.id, 2)
        XCTAssertEqual(player.queue.index, 0)
        XCTAssertEqual(player.queue.upNext.map(\.song.id), [4, 3, 1])
    }

    func testUnshuffleWhileASongStartsRestoresTheOrderAroundIt() async {
        player.shuffleOrder = { $0.sorted { $0.song.id > $1.song.id } }
        await player.play(Fixtures.songs(5), source: "")
        player.setShuffle(true)
        await player.next()
        await whileTheNextSongStarts { player.setShuffle(false) }
        XCTAssertEqual(player.current?.id, 4)
        XCTAssertEqual(player.queue.entries.map(\.song.id), [1, 2, 3, 4, 5])
        XCTAssertEqual(player.queue.upNext.map(\.song.id), [5])
    }

    func testAnInterruptionPausesAndItsEndResumesOnlyWhatWasPlaying() async {
        await player.play(Fixtures.songs(2), source: "")
        output.pause()
        await player.interrupted(.began)
        XCTAssertFalse(player.playing)
        XCTAssertEqual(center.shown.last??.playing, false)
        await player.toggle()
        XCTAssertTrue(player.playing, "one tap plays again after a call")
        XCTAssertFalse(output.isPaused)

        await player.interrupted(.began)
        await player.interrupted(.ended(shouldResume: true))
        XCTAssertTrue(player.playing)
        await player.pause()
        await player.interrupted(.began)
        await player.interrupted(.ended(shouldResume: true))
        XCTAssertFalse(player.playing, "a song paused before the call stays paused")
    }

    func testStopEndsTheSessionAndEmptiesTheQueue() async {
        await player.play(Fixtures.songs(2), source: "")
        await player.stop()
        XCTAssertEqual(ended, ["/playback/sessions/1"])
        XCTAssertNil(player.current)
        XCTAssertFalse(player.playing)
    }
}

extension MusicPlayerTests {
    func testAFailureWithTheServerOutOfReachStopsOnTheSongWithoutSkipping() async {
        await player.play(Fixtures.songs(3), source: "")
        transport.failure = URLError(.notConnectedToInternet)
        await player.outputFailed("The network connection was lost.")
        XCTAssertNil(player.alert)
        XCTAssertEqual(started, [1])
        XCTAssertEqual(player.current?.id, 1)
        XCTAssertFalse(player.playing)
        transport.failure = nil
        await player.resume()
        XCTAssertEqual(started, [1, 1])
        XCTAssertTrue(player.playing)
    }
}
