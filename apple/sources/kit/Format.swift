import Foundation
import RabbitEarsAPI

/// The short strings the boards use for times, rates and qualities.
public enum Format {
    public static func runtime(minutes: Int) -> String {
        let (hours, rest) = (minutes / 60, minutes % 60)
        if hours == 0 { return "\(rest)m" }
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }

    public static func remaining(ms: Int64) -> String {
        "\(runtime(minutes: Int((ms + 30_000) / 60_000))) left"
    }

    public static func clock(seconds: Double) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0))
        let (hours, minutes, secs) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    public static func bitrate(_ bitsPerSecond: Int64) -> String {
        if bitsPerSecond < 1_000_000 { return "\(bitsPerSecond / 1000) kb/s" }
        let mbps = Double(bitsPerSecond) / 1_000_000
        return mbps >= 10 || mbps == mbps.rounded()
            ? "\(Int(mbps.rounded())) Mb/s" : String(format: "%.1f Mb/s", mbps)
    }

    /// `4K` or `<rows>p` named by the nearest standard row count, so a 2.39:1
    /// 1080p file reads 1080p.
    public static func resolution(width: Int, height: Int) -> String {
        let rows = max(height, width * 9 / 16)
        if rows >= 2000 { return "4K" }
        let standard = [1440, 1080, 720, 576, 480, 360, 240]
        return "\(standard.first { rows >= $0 * 9 / 10 } ?? rows)p"
    }

    public static func resolution(height: Int) -> String {
        resolution(width: height * 16 / 9, height: height)
    }

    public static func verdict(_ verdict: Components.Schemas.Verdict) -> String {
        switch verdict {
        case .directPlay: "Direct play"
        case .remux: "Remux"
        case .audioTranscode: "Audio transcode"
        case .videoTranscode: "Transcode"
        }
    }

    /// With `auto`, the rung the player is on and Auto in place of the verdict.
    public static func pill(_ negotiated: Components.Schemas.Negotiated, auto: RungInUse? = nil) -> String {
        if let auto {
            return [resolution(height: auto.height), "Auto", bitrate(auto.bitrate)].joined(separator: " · ")
        }
        var quality = resolution(width: negotiated.width, height: negotiated.height)
        if negotiated.hdrFormat != nil { quality += " HDR" }
        return [quality, verdict(negotiated.verdict), bitrate(negotiated.bitrate)].joined(separator: " · ")
    }

    /// The details line: `Direct play on this device`, or how the server must convert.
    public static func playability(_ verdict: Components.Schemas.Verdict) -> String {
        "\(Self.verdict(verdict)) on this device"
    }

    /// Who a member is, under their name in the manage-household list.
    public static func member(_ account: Account, ownerId: Account.ID?) -> String {
        if account.pending {
            guard let expires = account.inviteExpiresAt else { return "Awaiting sign-in · code expired" }
            return "Awaiting sign-in · code expires \(expires.formatted(.dateTime.month(.abbreviated).day()))"
        }
        if account.kind == .adult { return account.id == ownerId ? "Owner" : "Adult" }
        guard account.filterMode == .ratings else { return "Kid · only titles you choose" }
        let ceilings = [
            account.movieCeiling.map { "movies up to \($0.rawValue)" },
            account.tvCeiling.map { "TV up to \($0.rawValue)" },
        ]
        return (["Kid"] + ceilings.compactMap { $0 }).joined(separator: " · ")
    }

    /// After `member` and the shared icon, for a member in another household too.
    public static func shared(_ account: Account) -> String? {
        if account.present == true { return "Visiting from another household" }
        guard let count = account.households, count > 1 else { return nil }
        return "In \(count) households"
    }

    /// "Kid · Helga offers to share Jason with your household", or "Kid · Offered to Helga, waiting".
    public static func offer(_ offer: ProfileOffer, incoming: Bool) -> String {
        let what =
            incoming
            ? "\(offer.fromName) offers to share \(offer.profileName) with your household"
            : "Offered to \(offer.toName), waiting"
        return "\(offer.profileKind == .kid ? "Kid" : "Adult") · \(what)"
    }

    public static func episodeCode(_ item: Item) -> String {
        "S\(item.seasonNumber ?? 0) E\(item.episodeNumber ?? 0)"
    }

    /// `1 title`, `12 titles`; every noun counted here takes an s.
    public static func count(_ count: Int, _ noun: String) -> String {
        count == 1 ? "1 \(noun)" : "\(count) \(noun)s"
    }

    public static func language(_ code: String?) -> String {
        guard let code, !code.isEmpty, code != "und" else { return "Unknown" }
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code.uppercased()
    }
}

extension String {
    /// The longest run of whole characters from the start within `limit`
    /// Unicode scalars, which is what the spec's maxLength counts.
    func prefix(scalars limit: Int) -> String {
        var count = 0
        let end = firstIndex { character in
            count += character.unicodeScalars.count
            return count > limit
        }
        return String(self[..<(end ?? endIndex)])
    }
}
