import Foundation
import RabbitEarsAPI

public enum Telemetry {
    /// Group E from what the player reports. The rung is named only when both
    /// its height and its declared bitrate are known: a plain file has no
    /// variants, and the player knows neither before the first frame.
    public static func sample(
        observedBitrate: Double, bufferSeconds: Double, stalls: Int, height: Double, indicatedBitrate: Double
    ) -> Components.Schemas.ThroughputTelemetry {
        var rung: RungInUse?
        if height.isFinite, indicatedBitrate.isFinite, height >= 1, indicatedBitrate >= 1 {
            rung = RungInUse(height: Int(height), bitrate: Int64(indicatedBitrate))
        }
        return .init(
            measuredBitrate: Int64(observedBitrate.isFinite ? max(0, observedBitrate) : 0),
            bufferMs: Int64(bufferSeconds.isFinite ? max(0, bufferSeconds) * 1000 : 0), stallCount: stalls,
            rungHeight: rung?.height, rungBitrate: rung?.bitrate)
    }
}
