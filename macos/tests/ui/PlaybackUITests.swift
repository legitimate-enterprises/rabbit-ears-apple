import XCTest

final class PlaybackUITests: XCTestCase {
    func testPlaysAFixture() throws {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["RABBIT_EARS_UI_SERVER"], let email = env["RABBIT_EARS_UI_EMAIL"],
            let password = env["RABBIT_EARS_UI_PASSWORD"]
        else {
            throw XCTSkip("Set RABBIT_EARS_UI_SERVER, _EMAIL and _PASSWORD for a server with fixtures scanned.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--signed-out"]
        app.launch()

        let serverField = app.textFields["Server"]
        XCTAssertTrue(serverField.waitForExistence(timeout: 10))
        serverField.click()
        serverField.typeKey("a", modifierFlags: .command)
        serverField.typeText(server)
        app.textFields["Email"].click()
        app.textFields["Email"].typeText(email)
        app.secureTextFields["Password"].click()
        app.secureTextFields["Password"].typeText(password + "\r")

        let adult = app.buttons.element(boundBy: 0)
        XCTAssertTrue(app.staticTexts["Who's watching?"].waitForExistence(timeout: 15))
        adult.click()

        let movies = app.outlines.staticTexts["Movies"]
        XCTAssertTrue(movies.waitForExistence(timeout: 15))
        movies.click()
        let firstTile = app.scrollViews.buttons.element(boundBy: 0)
        XCTAssertTrue(firstTile.waitForExistence(timeout: 15))
        firstTile.click()
        let play = app.buttons.matching(NSPredicate(format: "label IN {'Play', 'Resume'}")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 15))
        play.click()

        let pill = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Playback quality: '")).firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 30))
        XCTAssertTrue(
            ["Direct play", "Remux", "Audio transcode", "Transcode"].contains { pill.label.contains($0) }, pill.label)
    }
}
