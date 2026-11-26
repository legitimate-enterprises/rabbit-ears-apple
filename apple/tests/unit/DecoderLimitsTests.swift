import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

final class DecoderLimitsTests: XCTestCase {
    private func video(model: String) -> [Components.Schemas.VideoDecoder] {
        let facts = DeviceFacts(
            hardwareVideoCodecs: ["h264", "hevc", "av1"], hdrPlayback: false, audioDecoders: [], playableTypes: [],
            screen: nil, route: RouteFacts(channels: 2), path: PathFacts(), model: model)
        return CapabilitySnapshotBuilder.decoder(facts).videoCodecs
    }

    private func limits(_ video: [Components.Schemas.VideoDecoder]) -> [[String]] {
        video.map {
            [
                $0.codec, $0.profiles?.joined(separator: "/") ?? "", $0.maxLevel.map(String.init) ?? "-",
                "\($0.maxWidth)x\($0.maxHeight)", "\(Int($0.maxFrameRate))", "\($0.maxBitDepth)",
            ]
        }
    }

    /// support.apple.com/111928: H.264 to 1080p60 High or Main level 4.2, HEVC SDR to 1080p30.
    func testAppleTVHDReportsWhatItsHardwareDecodes() {
        XCTAssertEqual(
            limits(video(model: "AppleTV5,3")),
            [
                ["h264", "Main/High", "42", "1920x1080", "60", "8"],
                ["hevc", "Main/Main 10", "-", "1920x1080", "30", "10"],
            ])
    }

    func testAppleTVHDReportsNoHEVCWithoutHardwareHEVC() {
        let facts = DeviceFacts(
            hardwareVideoCodecs: ["h264"], hdrPlayback: false, audioDecoders: [], playableTypes: [], screen: nil,
            route: RouteFacts(channels: 2), path: PathFacts(), model: "AppleTV5,3")
        XCTAssertEqual(CapabilitySnapshotBuilder.decoder(facts).videoCodecs.map(\.codec), ["h264"])
    }

    func testEveryOtherModelKeepsTheDefaultLimits() {
        let defaults = [
            ["h264", "Constrained Baseline/Baseline/Main/High", "52", "4096x2304", "120", "8"],
            ["hevc", "Main/Main 10", "186", "8192x4320", "120", "10"],
            ["av1", "Main", "-", "8192x4320", "120", "10"],
        ]
        for model in ["AppleTV6,2", "AppleTV14,1", "iPhone17,1", "arm64", "x86_64", "AppleTV5", ""] {
            XCTAssertEqual(limits(video(model: model)), defaults, model)
        }
    }
}
