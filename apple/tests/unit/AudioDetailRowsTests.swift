import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

final class AudioDetailRowsTests: XCTestCase {
    private typealias Row = AudioDetailRow

    func testADirectPlayFlacListsEverySourceFactWithTheLosslessTag() {
        let audio = Components.Schemas.AudioDetails(
            source: .init(
                container: "flac", codec: "flac", bitrate: 2_116_000, sampleRateHz: 96000, bitDepth: 24, channels: 2,
                sizeBytes: 67_400_000, lossless: true),
            delivered: .init(verdict: .directPlay, codec: "flac", bitrate: 2_116_000, lossless: true))

        XCTAssertEqual(
            Format.audioDetails(audio),
            [
                AudioDetailGroup(
                    title: "Source",
                    rows: [
                        Row(label: "Format", value: "FLAC", tag: "Lossless"),
                        Row(label: "Bitrate", value: "2,116 kb/s"),
                        Row(label: "Sample rate", value: "96 kHz"),
                        Row(label: "Bit depth", value: "24-bit"),
                        Row(label: "Channels", value: "Stereo"),
                        Row(label: "Size", value: "67.4 MB"),
                    ]),
                AudioDetailGroup(
                    title: "Delivered",
                    rows: [
                        Row(label: "Playback", value: "Direct play", tone: .success),
                        Row(label: "Codec", value: "FLAC"),
                        Row(label: "Bitrate", value: "2,116 kb/s"),
                    ]),
            ])
    }

    func testATranscodeDeliversAnotherCodecAndBitrateWithCaution() {
        let audio = Components.Schemas.AudioDetails(
            source: .init(codec: "alac", bitrate: 1_411_200, sampleRateHz: 44100, channels: 1, lossless: true),
            delivered: .init(verdict: .audioTranscode, codec: "aac", bitrate: 256_000, lossless: false))

        let groups = Format.audioDetails(audio)

        XCTAssertEqual(
            groups.first?.rows,
            [
                Row(label: "Format", value: "ALAC", tag: "Lossless"),
                Row(label: "Bitrate", value: "1,411 kb/s"),
                Row(label: "Sample rate", value: "44.1 kHz"),
                Row(label: "Channels", value: "Mono"),
            ])
        XCTAssertEqual(
            groups.last?.rows,
            [
                Row(label: "Playback", value: "Audio transcode", tone: .caution),
                Row(label: "Codec", value: "AAC"),
                Row(label: "Bitrate", value: "256 kb/s"),
            ])
    }

    func testARemuxIsSuccessAndManyChannelsAreCounted() {
        let audio = Components.Schemas.AudioDetails(
            source: .init(codec: "mp3", channels: 6, lossless: false),
            delivered: .init(verdict: .remux, codec: "mp3", lossless: false))

        let groups = Format.audioDetails(audio)

        XCTAssertEqual(
            groups.first?.rows, [Row(label: "Format", value: "MP3"), Row(label: "Channels", value: "6 channels")])
        XCTAssertEqual(groups.last?.rows.first, Row(label: "Playback", value: "Remux", tone: .success))
    }

    /// Both groups, all nine rows: the most the panel ever holds.
    private var fullest: [AudioDetailGroup] {
        Format.audioDetails(
            .init(
                source: .init(
                    codec: "flac", bitrate: 2_116_000, sampleRateHz: 96000, bitDepth: 24, channels: 2,
                    sizeBytes: 67_400_000, lossless: true),
                delivered: .init(verdict: .audioTranscode, codec: "aac", bitrate: 256_000, lossless: false)))
    }

    func testTheFullestPanelKeepsTheDesignsMetricsWhereTheyFit() {
        XCTAssertEqual(fullest.flatMap(\.rows).count, 9)
        XCTAssertEqual(AudioDetailMetrics.regular.height(fullest), 324)
        XCTAssertEqual(AudioDetailMetrics.fitting(fullest, in: 326), .regular)
    }

    func testOnASmallPhoneRowsShrinkButKeepRoomForTheirText() {
        // An iPhone SE in portrait leaves the art about 214 points.
        for height in stride(from: 323.0, through: 205, by: -1) {
            let metrics = AudioDetailMetrics.fitting(fullest, in: height)
            XCTAssertLessThanOrEqual(metrics.height(fullest), height, "at \(height)")
            XCTAssertEqual(metrics.scale, 1, "at \(height)")
            XCTAssertGreaterThanOrEqual(metrics.row, 17, "at \(height)")
            XCTAssertLessThanOrEqual(metrics.row, 26, "at \(height)")
        }
    }

    func testBelowTheLeastReadableMetricsTheWholePanelScalesDown() {
        let metrics = AudioDetailMetrics.fitting(fullest, in: 120)
        XCTAssertLessThan(metrics.scale, 1)
        XCTAssertEqual(metrics.height(fullest), 120, accuracy: 0.001)
    }

    func testASourceWithNothingKnownIsLeftOut() {
        let audio = Components.Schemas.AudioDetails(
            source: .init(lossless: false), delivered: .init(verdict: .directPlay, codec: "aac", lossless: false))

        XCTAssertEqual(Format.audioDetails(audio).map(\.title), ["Delivered"])
    }
}
