import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

final class MediaSummaryTests: XCTestCase {
    let file = Fixtures.decode(
        #"{"id":"\#(UID.n(5))","itemId":"\#(UID.n(20))","path":"/media/Dune.Part.Two.2024.2160p.mkv","#
            + #""sizeBytes":24100000000,"fileModifiedAt":"2026-01-01T00:00:00Z","createdAt":"2026-01-01T00:00:00Z","#
            + #""modifiedAt":"2026-01-01T00:00:00Z","container":"mkv","durationMs":9960000,"bitrate":38000000,"#
            + #""chapters":[],"tracks":["#
            + #"{"id":"\#(UID.n(1))","streamIndex":0,"kind":"video","codec":"hevc","profile":"Main 10","width":3840,"#
            + #""height":2160,"hdrFormat":"hdr10","isDefault":true,"isForced":false},"#
            + #"{"id":"\#(UID.n(2))","streamIndex":1,"kind":"audio","codec":"truehd","language":"eng","channels":8,"#
            + #""isDefault":true,"isForced":false},"#
            + #"{"id":"\#(UID.n(3))","streamIndex":2,"kind":"audio","codec":"aac","language":"eng","channels":2,"#
            + #""isDefault":false,"isForced":false},"#
            + #"{"id":"\#(UID.n(4))","streamIndex":3,"kind":"subtitle","codec":"subrip","language":"eng","#
            + #""isDefault":false,"isForced":true,"subtitleIsText":true},"#
            + #"{"id":"\#(UID.n(5))","streamIndex":4,"kind":"subtitle","codec":"hdmv_pgs_subtitle","language":"eng","#
            + #""title":"SDH","isDefault":false,"isForced":false,"subtitleIsText":false}]}"#,
        as: Components.Schemas.MediaFile.self)

    func testDescribesTheVideo() {
        let summary = MediaSummary(file)
        XCTAssertEqual(summary.tags, ["4K", "HDR"])
        XCTAssertEqual(summary.videoLine, "4K HDR10 · HEVC · 38 Mb/s")
        XCTAssertEqual(summary.fileLine, "Dune.Part.Two.2024.2160p.mkv · 24.1 GB")
    }

    func testLabelsAudioAndSubtitleTracks() {
        let summary = MediaSummary(file)
        XCTAssertEqual(summary.audio.map(summary.label), ["English · 7.1", "English · Stereo"])
        XCTAssertEqual(summary.defaultAudio?.id, 2)
        XCTAssertEqual(summary.subtitles.map(summary.label), ["English (forced)", "English SDH"])
        XCTAssertEqual(summary.subtitleLine, "English (forced), English SDH")
    }

    /// A file of only subtitle tracks, each `language[/title][/forced]`.
    func line(_ tracks: [String]) -> String {
        let json = tracks.enumerated().map { index, spec in
            let parts = spec.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            let title = parts.count > 1 && parts[1] != "forced" ? #","title":"\#(parts[1])""# : ""
            let language = parts[0].isEmpty ? "" : #","language":"\#(parts[0])""#
            return #"{"id":"\#(UID.n(index))","streamIndex":\#(index),"kind":"subtitle","codec":"subrip""#
                + language + title + #","isDefault":false,"isForced":\#(parts.last == "forced")}"#
        }
        let file = Fixtures.decode(
            #"{"id":"\#(UID.n(1))","itemId":"\#(UID.n(1))","path":"/m.mkv","sizeBytes":1,"#
                + #""fileModifiedAt":"2026-01-01T00:00:00Z","createdAt":"2026-01-01T00:00:00Z","#
                + #""modifiedAt":"2026-01-01T00:00:00Z","container":"mkv","chapters":[],"tracks":["#
                + json.joined(separator: ",") + "]}",
            as: Components.Schemas.MediaFile.self)
        return MediaSummary(file).subtitleLine
    }

    func testSubtitleLineNamesEachTrackOnceAndSummarizesMany() {
        XCTAssertEqual(line(["eng"]), "English")
        XCTAssertEqual(line(["eng", "eng/SDH", "spa"]), "English, English SDH, Spanish")
        XCTAssertEqual(line(["eng", "eng/SDH", "spa", "fre", "ger"]), "English, English SDH, +3 other languages")
        XCTAssertEqual(line(["eng", "spa", "spa/SDH", "spa/forced"]), "English, +1 other language")
        XCTAssertEqual(line(["eng", "eng", "eng", "eng"]), "English")
        XCTAssertEqual(line(["spa", "fre", "ger", "ita"]), "4 languages")
        XCTAssertEqual(line(["spa", "spa/SDH", "spa", "spa"]), "Spanish, Spanish SDH")
        XCTAssertEqual(line(["eng/English SDH"]), "English SDH")
        XCTAssertEqual(line(["eng/forced"]), "English (forced)")
    }

    func testSubtitleLineTakesAnyEnglishCodeAndCountsUnknownAsOneLanguage() {
        XCTAssertEqual(line(["EN-us", "en_GB/SDH", "und", "", "spa"]), "English, English SDH, +2 other languages")
        XCTAssertEqual(line(["und", "", "und", "und"]), "Unknown")
    }
}
