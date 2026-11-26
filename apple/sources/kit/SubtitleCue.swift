import Foundation

/// One timed subtitle from a WebVTT or SRT sidecar, drawn by the player.
public struct SubtitleCue: Equatable, Sendable {
    public let start: Double
    public let end: Double
    public let text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }

    /// Reads WebVTT or SRT; markup tags and cue settings are dropped.
    public static func parse(_ text: String) -> [SubtitleCue] {
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        return blocks.compactMap { block in
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else { return nil }
            let times = lines[timing].components(separatedBy: "-->")
            guard times.count == 2, let start = seconds(times[0]),
                let end = seconds(
                    times[1].split(separator: " ", omittingEmptySubsequences: true).first.map(String.init))
            else { return nil }
            let body = lines[(timing + 1)...].joined(separator: "\n")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? nil : SubtitleCue(start: start, end: end, text: body)
        }
    }

    /// `hh:mm:ss.mmm`, `mm:ss.mmm`, with a comma or a dot before the milliseconds.
    static func seconds(_ text: String?) -> Double? {
        guard let text else { return nil }
        let parts = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
            .split(separator: ":").compactMap { Double($0) }
        guard (2...3).contains(parts.count) else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}

extension [SubtitleCue] {
    public func text(at seconds: Double) -> String? {
        first { $0.start <= seconds && seconds < $0.end }?.text
    }
}

extension PlayerModel {
    /// The choice after the current one, in the subtitle menu's order: Off,
    /// Forced only, then each track, round again.
    public func nextSubtitles(offeringTracks: Bool = true) async {
        let order = [SubtitleChoice.off, .forcedOnly] + (offeringTracks ? subtitleTracks.map { .track($0.id) } : [])
        let at = order.firstIndex(of: subtitleChoice) ?? 0
        await selectSubtitles(order[(at + 1) % order.count])
    }
}
