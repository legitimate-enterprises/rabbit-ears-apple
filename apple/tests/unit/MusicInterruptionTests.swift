import XCTest

@testable import RabbitEarsKit

extension MusicPlayerTests {
    func testAPauseDuringAnInterruptionHoldsWhenTheSystemSaysResume() async {
        await player.play(Fixtures.songs(1), source: "")
        output.pause()
        await player.interrupted(.began)
        await player.handle(.pause)
        await player.interrupted(.ended(shouldResume: true))
        XCTAssertFalse(player.playing)
        XCTAssertTrue(output.isPaused)
    }

    func testAnInterruptionTheSystemSaysNotToResumeIsForgotten() async {
        await player.play(Fixtures.songs(1), source: "")
        output.pause()
        await player.interrupted(.began)
        await player.interrupted(.ended(shouldResume: false))
        XCTAssertFalse(player.playing)
        await player.interrupted(.ended(shouldResume: true))
        XCTAssertFalse(player.playing, "a later recommendation ends no interruption of this song")
        XCTAssertTrue(output.isPaused)
    }

    func testNowPlayingStopsTheClockWhenTheSystemPausesTheOutput() async {
        await player.play(Fixtures.songs(1), source: "")
        XCTAssertEqual(center.shown.last??.playing, true)
        output.positionMs = 61_000
        output.pause()
        output.onPlayingChange?()
        XCTAssertEqual(center.shown.last??.elapsedMs, 61_000)
        XCTAssertEqual(center.shown.last??.playing, false, "the system counts on from the last rate it was given")
    }

    func testNowPlayingRunsOnlyOnceTheOutputPlaysAfterAnInterruption() async {
        await player.play(Fixtures.songs(1), source: "")
        output.positionMs = 30_000
        output.pause()
        await player.interrupted(.began)
        output.waits = true
        await player.interrupted(.ended(shouldResume: true))
        XCTAssertTrue(player.playing)
        XCTAssertEqual(center.shown.last??.elapsedMs, 30_000)
        XCTAssertEqual(center.shown.last??.playing, false, "nothing plays while the output waits")
        output.positionMs = 30_040
        output.isPlaying = true
        output.onPlayingChange?()
        XCTAssertEqual(center.shown.last??.elapsedMs, 30_040)
        XCTAssertEqual(center.shown.last??.playing, true)
    }

    func testAnOutputChangeWithNoSongPublishesNothing() async {
        await player.play(Fixtures.songs(1), source: "")
        await player.stop()
        let shown = center.shown.count
        output.onPlayingChange?()
        XCTAssertEqual(center.shown.count, shown)
    }
}
