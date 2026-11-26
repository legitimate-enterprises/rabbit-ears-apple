import XCTest

@testable import RabbitEarsKit

final class SubtitleCueTests: XCTestCase {
    func testParsesWebVTTWithSettingsAndTags() {
        let vtt = """
            WEBVTT

            NOTE a comment

            1
            00:00:01.000 --> 00:00:02.500 align:center
            <i>Hello</i> there

            01:02:03.250 --> 01:02:04.000
            Two
            lines
            """
        let cues = SubtitleCue.parse(vtt)
        XCTAssertEqual(
            cues,
            [
                SubtitleCue(start: 1, end: 2.5, text: "Hello there"),
                SubtitleCue(start: 3723.25, end: 3724, text: "Two\nlines"),
            ])
        XCTAssertEqual(cues.text(at: 1.2), "Hello there")
        XCTAssertNil(cues.text(at: 3))
    }

    func testParsesSRTCommaTimesAndWindowsLineEnds() {
        let srt = "1\r\n00:00:05,000 --> 00:00:06,000\r\nHi\r\n\r\n2\r\n00:10.000 --> 00:11.000\r\nShort\r\n"
        XCTAssertEqual(
            SubtitleCue.parse(srt),
            [
                SubtitleCue(start: 5, end: 6, text: "Hi"), SubtitleCue(start: 10, end: 11, text: "Short"),
            ])
    }
}
