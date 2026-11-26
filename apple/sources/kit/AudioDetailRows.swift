import Foundation
import RabbitEarsAPI

/// One fact on a song's file details panel.
public struct AudioDetailRow: Equatable, Sendable, Identifiable {
    public enum Tone: Sendable { case plain, success, caution }
    public let label: String
    public let value: String
    /// A short tag drawn before the value, such as "Lossless".
    public let tag: String?
    public let tone: Tone
    public var id: String { label }

    public init(label: String, value: String, tag: String? = nil, tone: Tone = .plain) {
        self.label = label
        self.value = value
        self.tag = tag
        self.tone = tone
    }
}

public struct AudioDetailGroup: Equatable, Sendable, Identifiable {
    public let title: String
    public let rows: [AudioDetailRow]
    public var id: String { title }
}

/// The panel's vertical metrics in points, fitted to the art's height so
/// every row shows without scrolling: the design's where they fit, else
/// rows and gaps shrink toward the least that holds 14-point text, and
/// below that the whole panel scales down.
public struct AudioDetailMetrics: Equatable, Sendable {
    /// Above the first group and below the last.
    public var padding: Double
    /// Each side.
    public var inset: Double
    /// A group's title with the space under it.
    public var heading: Double
    /// Between groups.
    public var gap: Double
    public var row: Double
    public var scale: Double

    public static let regular = AudioDetailMetrics(padding: 18, inset: 20, heading: 20, gap: 14, row: 26, scale: 1)
    static let least = AudioDetailMetrics(padding: 8, inset: 12, heading: 16, gap: 4, row: 17, scale: 1)

    public func height(_ groups: [AudioDetailGroup]) -> Double {
        let rows = groups.reduce(0) { $0 + $1.rows.count }
        let spacing = 2 * padding + Double(groups.count) * heading + Double(max(0, groups.count - 1)) * gap
        return (spacing + Double(rows) * row) * scale
    }

    public static func fitting(_ groups: [AudioDetailGroup], in height: Double) -> AudioDetailMetrics {
        if regular.height(groups) <= height { return regular }
        var metrics = least
        let spare = height - least.height(groups)
        let rows = groups.reduce(0) { $0 + $1.rows.count }
        if spare < 0 {
            // Never zero, so a view can divide by it.
            metrics.scale = max(1, height) / least.height(groups)
        } else if rows > 0 {
            metrics.row = min(regular.row, least.row + spare / Double(rows))
        }
        return metrics
    }
}

extension Format {
    /// The file details panel: the file on the server, then what reaches this
    /// device. Facts the server does not know are left out, and so is a group
    /// left empty.
    public static func audioDetails(_ audio: Components.Schemas.AudioDetails) -> [AudioDetailGroup] {
        let source = audio.source
        let delivered = audio.delivered
        let sourceRows: [AudioDetailRow?] = [
            source.codec.map {
                AudioDetailRow(label: "Format", value: codec($0), tag: source.lossless ? "Lossless" : nil)
            },
            source.bitrate.map { AudioDetailRow(label: "Bitrate", value: kilobits($0)) },
            source.sampleRateHz.map { AudioDetailRow(label: "Sample rate", value: kilohertz($0)) },
            source.bitDepth.map { AudioDetailRow(label: "Bit depth", value: "\($0)-bit") },
            source.channels.map { AudioDetailRow(label: "Channels", value: channels($0)) },
            source.sizeBytes.map { AudioDetailRow(label: "Size", value: bytes($0)) },
        ]
        let deliveredRows: [AudioDetailRow?] = [
            AudioDetailRow(
                label: "Playback", value: verdict(delivered.verdict),
                tone: [.directPlay, .remux].contains(delivered.verdict) ? .success : .caution),
            AudioDetailRow(label: "Codec", value: codec(delivered.codec)),
            delivered.bitrate.map { AudioDetailRow(label: "Bitrate", value: kilobits($0)) },
        ]
        return [
            AudioDetailGroup(title: "Source", rows: sourceRows.compactMap { $0 }),
            AudioDetailGroup(title: "Delivered", rows: deliveredRows.compactMap { $0 }),
        ].filter { !$0.rows.isEmpty }
    }

    /// `2,116 kb/s`: audio rates read in whole kilobits, never megabits.
    static func kilobits(_ bitsPerSecond: Int64) -> String {
        "\(Int64((Double(bitsPerSecond) / 1000).rounded()).formatted()) kb/s"
    }

    static func kilohertz(_ hertz: Int) -> String {
        "\((Double(hertz) / 1000).formatted(.number.precision(.fractionLength(0...1)))) kHz"
    }

    static func channels(_ count: Int) -> String {
        switch count {
        case 1: "Mono"
        case 2: "Stereo"
        default: "\(count) channels"
        }
    }
}
