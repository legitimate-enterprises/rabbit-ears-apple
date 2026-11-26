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

        let profile = app.buttons[demo.profile]
        XCTAssertTrue(profile.waitForExistence(timeout: 20))
        captureStoreImage("01-profiles", app: app)
        profile.tap()
        let movies = app.tabBars.buttons["Movies"]
        XCTAssertTrue(movies.waitForExistence(timeout: 20))
        // iOS offers to save the password just typed, over the whole app and some seconds after
        // sign-in. Nothing under the offer takes a tap, so it is declined here, where it most
        // often shows, and before any tap it still covers. The offer is Safari's view service's,
        // and its Not Now is not a button to XCTest.
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
    }
}
