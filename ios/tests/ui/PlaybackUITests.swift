import XCTest

/// Exercises the real sign-in, profile, catalog and video-player boundaries.
@MainActor
final class PlaybackUITests: XCTestCase {
    func testBrowseAndPlayFixture() throws {
        continueAfterFailure = false
        let demo = try DemoConfiguration()
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }

        let server = app.textFields["Server"]
        XCTAssertTrue(server.waitForExistence(timeout: 15))
        server.tap()
        server.typeText(demo.server)
        app.textFields["Email"].tap()
        app.textFields["Email"].typeText(demo.email)
        app.secureTextFields["Password"].tap()
        app.secureTextFields["Password"].typeText(demo.password + "\n")

        // iOS offers to save the password just typed, over the whole app and some seconds after
        // sign-in. Nothing under the offer takes a tap, so it is declined before any tap it
        // covers, and once more after the profile, where it most often shows. The offer is
        // Safari's view service's, and its Not Now is not a button to XCTest.
        let offer = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        let decline = offer.descendants(matching: .any)["Not Now"].firstMatch
        func tap(_ element: XCUIElement) {
            let deadline = Date().addingTimeInterval(15)
            while !element.isHittable, Date() < deadline {
                if decline.waitForExistence(timeout: 0.5) { decline.tap() }
            }
            XCTAssertTrue(element.isHittable)
            element.tap()
        }

        let profile = app.buttons[demo.profile]
        XCTAssertTrue(profile.waitForExistence(timeout: 20))
        captureStoreImage("01-profiles", app: app)
        tap(profile)
        let movies = app.tabBars.buttons["Movies"]
        XCTAssertTrue(movies.waitForExistence(timeout: 20))
        if decline.waitForExistence(timeout: 8) { decline.tap() }
        let title = app.staticTexts[demo.movie].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        captureStoreImage("02-home", app: app)
        tap(movies)
        tap(title)
        let play = app.buttons.matching(NSPredicate(format: "label IN {'Play', 'Resume'}")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 15))
        captureStoreImage("03-movie-details", app: app)
        tap(play)
        assertPlaybackStarted(in: app)

        // Off the play button, on the video itself.
        let video = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let quality = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Playback quality: '")).firstMatch
        let menu = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Only for non-English'")).firstMatch
        // From controls just brought back, so they cannot fade before the tap lands.
        XCTAssertTrue(quality.waitForNonExistence(timeout: 10), "the controls fade while the video plays")
        video.tap()
        app.buttons["Subtitles"].tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        // Open for longer than the controls wait before they fade.
        Thread.sleep(forTimeInterval: 4)
        XCTAssertTrue(menu.exists)
        video.tap()
        XCTAssertFalse(menu.exists)
        XCTAssertTrue(quality.waitForNonExistence(timeout: 10), "the controls fade once a closed menu leaves them idle")
    }
}
