import Foundation
import RabbitEarsAPI

/// What the viewer asked for. Auto is the default until they pick another;
/// a rung is named by its bitrate, which is also the cap sent to the server.
public enum QualityChoice: Hashable, Sendable {
    case auto, original
    case rung(Int64)

    public var maxBitrate: Int64? {
        if case .rung(let bitrate) = self { bitrate } else { nil }
    }
}

/// The variant the player is on, which in Auto the player picks itself.
public struct RungInUse: Equatable, Sendable {
    public let height: Int
    public let bitrate: Int64

    public init(height: Int, bitrate: Int64) {
        self.height = height
        self.bitrate = bitrate
    }
}

extension PlayerModel {
    public struct QualityOption: Identifiable, Equatable, Sendable {
        public let choice: QualityChoice
        public let name: String
        public let detail: String
        public let verdict: Components.Schemas.Verdict
        public let selected: Bool
        /// Listed but not playable on this network path.
        public let blocked: Bool
        public var id: QualityChoice { choice }
        public var verdictLabel: String { Format.verdict(verdict) }
        public var trailingLabel: String { blocked ? "Wi-Fi only" : verdictLabel }
    }
}
