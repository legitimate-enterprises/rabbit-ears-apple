import XCTest

/// Uses the TV's password flow so device linking never needs manual approval.
@MainActor
final class PlaybackUITests: XCTestCase {
    func testBrowseAndPlayFixture() throws {
        continueAfterFailure = false
        let demo = try DemoConfiguration()
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }

        select(app.buttons["Enter an address"], in: app)
        let server = app.textFields["Server address"]
        XCTAssertTrue(server.waitForExistence(timeout: 10))
        select(server, in: app)
        server.typeText(demo.server + "\n")
        select(app.buttons["Sign in with a password instead"], in: app)
        enter(demo.email, into: app.textFields["Email"], in: app)
        enter(demo.password, into: app.secureTextFields["Password"], in: app)
        select(app.buttons["Sign in"], in: app)

        let profile = app.buttons[demo.profile]
        XCTAssertTrue(profile.waitForExistence(timeout: 20))
        captureStoreImage("01-profiles", app: app)
        select(profile, in: app)
        let movies = app.buttons["section-movies"]
        XCTAssertTrue(movies.waitForExistence(timeout: 20))
        let title = app.staticTexts[demo.movie].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        captureStoreImage("02-home", app: app)
        select(movies, in: app)
        let tile = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", demo.movie)).firstMatch
        select(tile, in: app)
        let play = app.buttons.matching(NSPredicate(format: "label IN {'Play', 'Resume'}")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 15))
        captureStoreImage("03-movie-details", app: app)
        select(play, in: app)
        assertPlaybackStarted(in: app)
    }

    private func enter(_ text: String, into field: XCUIElement, in app: XCUIApplication) {
        select(field, in: app)
        field.typeText(text)
        XCUIRemote.shared.press(.menu)
    }

    /// Focus movement uses the real remote and fails if the target cannot be reached.
    private func select(_ target: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(target.waitForExistence(timeout: 15))
        for _ in 0..<30 {
            if target.hasFocus {
                XCUIRemote.shared.press(.select)
                return
            }
            let focused = app.descendants(matching: .any)
                .matching(NSPredicate(format: "hasFocus == true")).firstMatch
            // Focus lands a moment after a screen or the keyboard changes.
            XCTAssertTrue(
                focused.waitForExistence(timeout: 5), "No focused control while navigating to " + target.label)
            let destination = target.frame
            let origin = focused.frame
            let direction: XCUIRemote.Button
            if destination.minY >= origin.maxY {
                direction = .down
            } else if destination.maxY <= origin.minY {
                direction = .up
            } else {
                direction = destination.midX > origin.midX ? .right : .left
            }
            XCUIRemote.shared.press(direction)
        }
        XCTFail("Could not focus " + target.label)
    }
}
