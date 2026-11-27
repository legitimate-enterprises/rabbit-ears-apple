import AVFoundation
import XCTest

@testable import RabbitEarsKit

final class ControlsFadeTests: XCTestCase {
    func testFadeStartsSoonerAndEndsWhenTheControlsUsedToVanish() {
        XCTAssertEqual(ControlsFade.delay, 2)
        XCTAssertEqual(ControlsFade.remoteDelay, 3)
        XCTAssertEqual(ControlsFade.fade, 1)
        XCTAssertEqual(ControlsFade.delay + ControlsFade.fade, 3)
        XCTAssertEqual(ControlsFade.remoteDelay + ControlsFade.fade, 4)
    }
}

/// The wait before the fade, on a real AVPlayer: playback that starts or
/// resumes with no touch on the player, as autoplay, a station, a slow
/// start or a remote command does, still lets the controls go.
@MainActor
final class ControlsIdleTests: XCTestCase {
    func testPlaybackThatStartsAfterTheDelayStillLetsTheControlsGo() async throws {
        let player = AVPlayer(url: try AVAudioOutputTests.audioFile(seconds: 5))
        let idle = Task { await ControlsFade.idle(player, for: 0.3) }
        try await Task.sleep(for: .milliseconds(600))
        player.play()
        let started = ContinuousClock.now
        let gone = await idle.value
        XCTAssertTrue(gone)
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .milliseconds(300), "a full delay of playing")
        player.pause()
    }

    func testAPauseHoldsTheControlsUntilPlaybackResumes() async throws {
        let player = AVPlayer(url: try AVAudioOutputTests.audioFile(seconds: 5))
        player.play()
        var done = false
        let idle = Task {
            let gone = await ControlsFade.idle(player, for: 0.3)
            done = true
            return gone
        }
        try await Task.sleep(for: .milliseconds(100))
        player.pause()
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(done, "paused at the end of the delay")
        player.play()
        let gone = await idle.value
        XCTAssertTrue(gone)
        player.pause()
    }

    func testCancellingTheWaitKeepsTheControls() async throws {
        let player = AVPlayer(url: try AVAudioOutputTests.audioFile(seconds: 5))
        let idle = Task { await ControlsFade.idle(player, for: 0.3) }
        try await Task.sleep(for: .milliseconds(500))
        idle.cancel()
        let gone = await idle.value
        XCTAssertFalse(gone)
    }
}
