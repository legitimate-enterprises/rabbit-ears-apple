import AVFoundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// The music player on a real AVPlayer, streaming a generated file.
@MainActor
final class AVAudioOutputTests: XCTestCase {
    var transport: RoutingTransport!
    var output: AVAudioOutput!
    var center: FakeNowPlaying!
    var player: RabbitEarsKit.MusicPlayer!

    override func setUp() async throws {
        let file = try Self.audioFile(seconds: 5)
        let stream = Fixtures.audioStream(1).replacingOccurrences(
            of: "/api/v2/streams/s\(UID.n(1))/0/file", with: file.absoluteString)
        transport = RoutingTransport()
        transport.respond = { sent in
            switch (sent.method, sent.path) {
            case (.post, "/playback/sessions"): (.created, stream)
            case (.delete, _), (.put, _): (.noContent, "")
            default: nil
            }
        }
        output = AVAudioOutput()
        center = FakeNowPlaying()
        let server = ServerEndpoint(userInput: "192.168.1.9")!
        player = RabbitEarsKit.MusicPlayer(
            client: server.client(token: "t", transport: transport), endpoint: server, profileId: 1, output: output,
            capabilities: FakeCapabilities(), activateSession: {})
        player.attach(center)
    }

    override func tearDown() async throws {
        await player.stop()
    }

    func testNowPlayingRunsOnlyWhileTheAudioDoes() async throws {
        await player.play(Fixtures.songs(1), source: "")
        XCTAssertEqual(output.player.rate, 1, "AVPlayer keeps the rate asked for while it waits")
        XCTAssertEqual(center.shown.last??.playing, false)
        try await until { self.center.shown.last??.playing == true }
        try await Task.sleep(for: .milliseconds(400))

        // As the system does when Siri takes the session.
        output.player.pause()
        try await until { self.center.shown.last??.playing == false }
        let paused = try XCTUnwrap(center.shown.last ?? nil)
        XCTAssertGreaterThan(paused.elapsedMs, 200)
        XCTAssertEqual(Double(paused.elapsedMs), Double(output.positionMs), accuracy: 50)
    }

    func testAnInterruptionResumesFromWhereTheAudioStopped() async throws {
        await player.play(Fixtures.songs(1), source: "")
        try await until { self.center.shown.last??.playing == true }
        try await Task.sleep(for: .milliseconds(400))
        output.player.pause()
        await player.interrupted(.began)
        let stopped = output.positionMs
        try await Task.sleep(for: .milliseconds(600))

        await player.interrupted(.ended(shouldResume: true))
        try await until { self.center.shown.last??.playing == true }
        let resumed = try XCTUnwrap(center.shown.last ?? nil)
        XCTAssertEqual(Double(resumed.elapsedMs), Double(stopped), accuracy: 100, "no time passes paused")
        XCTAssertTrue(player.playing)
    }

    func testASeekShowsWhereItLandsAtOnce() async throws {
        await player.play(Fixtures.songs(1), source: "")
        try await until { self.center.shown.last??.playing == true }
        await player.pause()
        player.seek(toMs: 3000)
        XCTAssertEqual(center.shown.last??.elapsedMs, 3000, "a paused song publishes nothing more until it plays")
        XCTAssertEqual(player.positionMs, 3000)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(player.positionMs, 3000)
    }

    /// Silence, which AVPlayer plays like any song.
    static func audioFile(seconds: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("silence-\(seconds).caf")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let frames = AVAudioFrameCount(44_100 * seconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        return url
    }
}

/// The video player's output on a real AVPlayer.
@MainActor
final class AVPlayerOutputTests: XCTestCase {
    func testARestartReportsWhereItStartsBeforeItsItemIsReady() async throws {
        let output = AVPlayerOutput()
        let file = try AVAudioOutputTests.audioFile(seconds: 5)
        output.load(file, startingAt: 1)
        try await until { output.player.currentItem?.status == .readyToPlay }
        output.load(file, startingAt: 3)
        XCTAssertEqual(output.positionMs, 3000, "a report now restarts the stream from here")
        try await until { output.player.currentItem?.status == .readyToPlay }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(output.positionMs, 3000)
        output.stop()
    }

    func testAnItemPrefersTheForwardBufferItsStreamNames() async throws {
        let output = AVPlayerOutput()
        let file = try AVAudioOutputTests.audioFile(seconds: 5)
        let server = ServerEndpoint(userInput: "192.168.1.9")!
        let transport = RoutingTransport()
        let model = PlayerModel(
            client: server.client(token: "t", transport: transport), endpoint: server, profileId: 2,
            item: Fixtures.decode(Fixtures.item(20, "movie", "Dune"), as: Item.self), output: output,
            capabilities: FakeCapabilities())
        for (extra, goal) in [(#","bufferGoalSeconds":120"#, 120.0), ("", 0)] {
            transport.routes["POST /playback/sessions"] = (
                .created, Fixtures.stream(url: file.absoluteString, extra: extra)
            )
            await model.start()
            XCTAssertEqual(output.player.currentItem?.preferredForwardBufferDuration, goal)
        }
        await model.stop()
    }
}

@MainActor
private func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    for _ in 0..<250 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertTrue(condition(), "timed out", file: file, line: line)
}

@MainActor
final class AVAudioOutputReleaseTests: XCTestCase {
    func testAReleasedOutputDeinitializes() {
        weak var released: AVAudioOutput?
        do {
            let output = AVAudioOutput()
            released = output
        }
        XCTAssertNil(released)
    }
}
