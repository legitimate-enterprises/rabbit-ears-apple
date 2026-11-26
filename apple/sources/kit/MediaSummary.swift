import Foundation
import RabbitEarsAPI

public typealias Track = Components.Schemas.Track

/// What the details screens say about one media file's tracks.
public struct MediaSummary: Sendable {
    public let file: Components.Schemas.MediaFile

    public init(_ file: Components.Schemas.MediaFile) { self.file = file }

    public var video: Track? { file.tracks.first { $0.kind == .video } }
    public var audio: [Track] { file.tracks.filter { $0.kind == .audio } }
    public var subtitles: [Track] { file.tracks.filter { $0.kind == .subtitle } }
    public var defaultAudio: Track? { audio.first(where: \.isDefault) ?? audio.first }

    public var tags: [String] {
        guard let video, let width = video.width, let height = video.height else { return [] }
        var tags: [String] = []
        if Format.resolution(width: width, height: height) == "4K" { tags.append("4K") }
        if video.hdrFormat != nil { tags.append("HDR") }
        return tags
    }

    /// Such as `4K HDR10 · HEVC · 38 Mb/s`.
    public var videoLine: String? {
        guard let video else { return nil }
        var quality = Format.resolution(width: video.width ?? 0, height: video.height ?? 0)
        if let hdr = video.hdrFormat { quality += " " + Self.hdrNames[hdr, default: "HDR"] }
        var parts = [quality, video.codec.uppercased()]
        if let bitrate = file.bitrate { parts.append(Format.bitrate(bitrate)) }
        return parts.joined(separator: " · ")
    }

    /// Every subtitle label when there are three tracks or fewer; past that, the English
    /// labels and a count of the other languages, or the count alone with no English
    /// unless that is one language.
    public var subtitleLine: String {
        let labels = Self.distinct(subtitles.map(label))
        let english = subtitles.filter { Self.isEnglish($0.language) }
        let others = Set(subtitles.filter { !Self.isEnglish($0.language) }.map { Format.language($0.language) })
        guard subtitles.count > 3, !(english.isEmpty && others.count == 1) else {
            return labels.joined(separator: ", ")
        }
        if english.isEmpty { return "\(others.count) languages" }
        var parts = Self.distinct(english.map(label))
        if !others.isEmpty { parts.append("+\(others.count) other language" + (others.count == 1 ? "" : "s")) }
        return parts.joined(separator: ", ")
    }

    public var fileLine: String {
        let name = URL(fileURLWithPath: file.path).lastPathComponent
        return "\(name) · \(ByteCountFormatter.string(fromByteCount: file.sizeBytes, countStyle: .decimal))"
    }

    /// `English · 5.1` for audio; `English SDH` or `English (forced)` for subtitles.
    public func label(_ track: Track) -> String {
        let language = Format.language(track.language)
        if track.kind == .audio {
            let channels = track.channels.map { Self.channelNames[$0] ?? "\($0) ch" } ?? track.codec.uppercased()
            return "\(language) · \(channels)"
        }
        var label = language
        if let title = track.title {
            label = title.localizedCaseInsensitiveContains(language) ? title : "\(language) \(title)"
        }
        if track.isForced { label += " (forced)" }
        return label
    }

    static func isEnglish(_ code: String?) -> Bool {
        let base = code?.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first
        return base == "en" || base == "eng"
    }

    static func distinct(_ labels: [String]) -> [String] {
        var seen: Set<String> = []
        return labels.filter { seen.insert($0).inserted }
    }

    static let hdrNames: [Components.Schemas.HdrFormat: String] = [
        .hdr10: "HDR10", .hdr10plus: "HDR10+", .dolbyVision: "Dolby Vision", .hlg: "HLG",
    ]
    static let channelNames = [1: "Mono", 2: "Stereo", 6: "5.1", 8: "7.1"]
}
