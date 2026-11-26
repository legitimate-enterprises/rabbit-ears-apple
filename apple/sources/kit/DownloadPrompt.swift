import Foundation
import Observation
import RabbitEarsAPI

extension DownloadQuality {
    public var label: String {
        switch self {
        case .original: "Original"
        case .aac256: "AAC 256"
        default: rawValue
        }
    }

    /// What Download offers, the profile's default first: Original or AAC 256 for music, else the picture sizes.
    public static func choices(music: Bool, preferred: DownloadQuality = .original) -> [DownloadQuality] {
        let all: [DownloadQuality] = music ? [.original, .aac256] : [.original, ._1080p, ._720p, ._480p, ._360p]
        let first: DownloadQuality =
            music ? (preferred == .original ? .original : .aac256) : (preferred == .aac256 ? .original : preferred)
        return [first] + all.filter { $0 != first }
    }
}

extension Format {
    /// A size as people read it: `1.2 GB`.
    public static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

/// A Download picked from a More menu: kept at once, or held as the big
/// request to confirm, "This is a lot".
@MainActor
@Observable
public final class DownloadPrompt {
    public var asking: DownloadPlan?
    public var error: String?

    public init() {}

    public func ask(_ target: DownloadTarget, quality: DownloadQuality, store: DownloadStore, profile: Int64) {
        Task {
            do {
                asking = try await store.request(target, quality: quality, profile: profile)
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// "51 titles, about 12.3 GB."
    public static func message(_ plan: DownloadPlan) -> String {
        let titles = Format.count(plan.count, "title")
        return "\(titles), about \(Format.bytes(plan.sizeBytes)), on this device."
    }
}

extension DownloadStore {
    /// Asks again for every title of the request that failed.
    public func retry(_ request: DownloadRequest) {
        for id in request.titles { retry(id) }
    }

    /// Whether any title of the request failed, for its Retry.
    public func failed(_ request: DownloadRequest) -> Bool {
        request.titles.contains { if case .failed = ledger.titles[$0]?.state { true } else { false } }
    }
}
