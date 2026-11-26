import XCTest

/// The local demo server supplies public, disposable identities and a known movie.
struct DemoConfiguration {
    let server: String
    let email: String
    let password: String
    let profile: String
    let movie: String

    init() throws {
        let environment = ProcessInfo.processInfo.environment
        func required(_ key: String) throws -> String {
            guard let value = environment["RABBIT_EARS_UI_" + key], !value.isEmpty else {
                throw NSError(
                    domain: "DemoConfiguration", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Run make test-ui or make screenshots; missing " + key])
            }
            return value
        }
        server = try required("SERVER")
        email = try required("EMAIL")
        password = try required("PASSWORD")
        profile = try required("PROFILE")
        movie = try required("MOVIE")
    }
}

@MainActor
extension XCTestCase {
    /// Store exports include only these named attachments, never failure diagnostics.
    func captureStoreImage(_ name: String, app: XCUIApplication) {
        guard ProcessInfo.processInfo.environment["RABBIT_EARS_UI_SCREENSHOTS"] == "1" else { return }
        // Local artwork loads asynchronously; require the rendered page to settle before capture.
        var previous = app.screenshot().pngRepresentation
        var stable = 0
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.25)
            let current = app.screenshot().pngRepresentation
            stable = current == previous ? stable + 1 : 0
            previous = current
            if stable >= 4 { break }
        }
        XCTAssertGreaterThanOrEqual(stable, 4, "The screenshot did not settle: " + name)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "store-" + name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func assertPlaybackStarted(in app: XCUIApplication) {
        let quality = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Playback quality: '")).firstMatch
        XCTAssertTrue(quality.waitForExistence(timeout: 30))
        let mode = quality.label
        XCTAssertTrue(["Direct play", "Remux", "Audio transcode", "Transcode"].contains { mode.contains($0) }, mode)
        let seek = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Seek'")).firstMatch
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if !seek.exists {
                #if os(tvOS)
                    XCUIRemote.shared.press(.down)
                #else
                    app.tap()
                #endif
            }
            if seek.exists, let value = seek.value as? String {
                let parts = value.split(separator: ":").compactMap { Double($0) }
                if parts.count >= 2, parts.reduce(0, { $0 * 60 + $1 }) > 0 { return }
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTFail("Playback must advance beyond zero; a quality label alone is insufficient.")
    }
}
