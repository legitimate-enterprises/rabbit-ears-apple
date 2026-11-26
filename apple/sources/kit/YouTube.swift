import Foundation
import RabbitEarsAPI

public typealias YouTubeChannel = Components.Schemas.YouTubeChannel
public typealias YouTubeVideo = Components.Schemas.YouTubeVideo
public typealias YouTubeVideoSort = Components.Schemas.YouTubeVideoSort
public typealias YouTubeChannelSort = Components.Schemas.YouTubeChannelSort

extension YouTubeVideoSort {
    /// The Sort menu's name for it.
    public var title: String {
        switch self {
        case .newest: "Newest"
        case .oldest: "Oldest"
        case .title: "Title"
        case .channel: "Channel"
        case .length: "Length"
        case .played: "Recently played"
        }
    }
}

/// What the YouTube screen shows. Unwatched is Videos filtered by a chip, so only Videos and Channels are tabs.
public enum YouTubeTab: String, CaseIterable, Sendable {
    case videos = "Videos"
    case channels = "Channels"
    case unwatched = "Unwatched"

    public static let tabs: [YouTubeTab] = [.videos, .channels]

    /// The tab this sits under.
    public var tab: YouTubeTab { self == .channels ? .channels : .videos }
}

/// Channel: the header and every video in the chosen order.
public struct ChannelDetail: Equatable, Sendable {
    public let channel: YouTubeChannel
    public let videos: [YouTubeVideo]
}

/// Video: the video and More from its channel, newest first.
public struct VideoDetail: Equatable, Sendable {
    public let video: YouTubeVideo
    public let moreFromChannel: [YouTubeVideo]
}

/// Reads the YouTube catalog for the active profile. The server leaves out,
/// and answers 404 for, what a kid may not see, so nothing here checks the
/// profile kind.
@MainActor
public final class YouTubeModel {
    public let client: Client
    public let profileId: Int64

    public init(client: Client, profileId: Int64) {
        self.client = client
        self.profileId = profileId
    }

    /// Home's New from your channels.
    public func newFromChannels(limit: Int = 20) async throws -> [YouTubeVideo] {
        try await videos(unwatched: true, limit: limit).items
    }

    /// Home's Continue watching videos: those with a resume position, latest played first.
    public func inProgress(limit: Int = 20) async throws -> [YouTubeVideo] {
        try await call {
            try await client.listYouTubeVideos(query: .init(inProgress: true, sort: .played, limit: limit)).ok.body.json
                .items
        }
    }

    /// One page of the Videos view; `query` is the toolbar search.
    public func videos(
        sort: YouTubeVideoSort = .newest, channelId: Int64? = nil,
        unwatched: Bool = false, query: String? = nil, offset: Int? = nil, limit: Int = 100
    ) async throws -> Components.Schemas.YouTubeVideoPage {
        try await call {
            try await client.listYouTubeVideos(
                query: .init(
                    channelId: channelId, unwatched: unwatched ? true : nil,
                    q: query.map { String($0.prefix(200)) }, sort: sort, limit: limit, offset: offset)
            ).ok.body.json
        }
    }

    public func channels(sort: YouTubeChannelSort = .title) async throws -> [YouTubeChannel] {
        try await call {
            try await allPages { offset in
                let page = try await self.client.listYouTubeChannels(
                    query: .init(sort: sort, limit: 200, offset: offset)
                ).ok.body.json
                return (page.items, page.nextOffset)
            }
        }
    }

    public func channel(_ id: Int64, sort: YouTubeVideoSort = .newest) async throws -> ChannelDetail {
        try await call {
            async let channel = client.getYouTubeChannel(path: .init(channelId: id)).ok.body.json
            async let videos = allPages { offset in
                let page = try await self.client.listYouTubeVideos(
                    query: .init(channelId: id, sort: sort, limit: 200, offset: offset)
                ).ok.body.json
                return (page.items, page.nextOffset)
            }
            return ChannelDetail(channel: try await channel, videos: try await videos)
        }
    }

    public func video(_ id: Int64) async throws -> VideoDetail {
        try await call {
            let video = try await client.getYouTubeVideo(path: .init(videoId: id)).ok.body.json
            let more = try await client.listYouTubeVideos(
                query: .init(channelId: video.channelId, sort: .newest, limit: 13)
            ).ok.body.json.items
            return VideoDetail(video: video, moreFromChannel: Array(more.filter { $0.id != id }.prefix(12)))
        }
    }

    public func setWatched(_ watched: Bool, channel id: Int64) async throws {
        try await call {
            _ = try await client.putYouTubeChannelWatchState(
                path: .init(profileId: profileId, channelId: id), body: .json(.init(watched: watched))
            ).noContent
        }
    }

    /// Any adult marks a channel for kids, which kids under rating ceilings then see.
    public func setForKids(_ forKids: Bool, channel id: Int64) async throws -> YouTubeChannel {
        try await call {
            try await client.setYouTubeChannelForKids(path: .init(channelId: id), body: .json(.init(forKids: forKids)))
                .ok.body.json
        }
    }

    /// Marks a selection of channels and videos in one request; a channel marks each video.
    public func setWatched(_ watched: Bool, items ids: [Int64]) async throws {
        try await call {
            _ = try await client.putWatchStates(
                path: .init(profileId: profileId), body: .json(.init(itemIds: ids, watched: watched))
            ).noContent
        }
    }

    public func setForKids(_ forKids: Bool, channels ids: [Int64]) async throws {
        try await call {
            _ = try await client.setKidsContents(body: .json(.init(itemIds: ids, kidsContent: forKids))).noContent
        }
    }

    private func call<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch { throw AppError.from(error, unauthorized: .signedOut) }
    }
}

/// One entry of Home's Continue watching: a catalog title or a YouTube video.
public enum Resumable: Identifiable, Sendable {
    case item(Item)
    case video(YouTubeVideo)

    public var id: String {
        switch self {
        case .item(let item): "item/\(item.id)"
        case .video(let video): "video/\(video.id)"
        }
    }

    /// An episode goes by its show's title.
    public func title(_ catalog: Catalog) -> String {
        switch self {
        case .item(let item): Catalog.title(catalog.show(of: item) ?? item)
        case .video(let video): video.title
        }
    }

    public func line(_ catalog: Catalog) -> String {
        switch self {
        case .item(let item): EpisodeText.line(item, catalog)
        case .video(let video): video.resumeLine
        }
    }

    public func progress(_ catalog: Catalog) -> Double? {
        switch self {
        case .item(let item): catalog.progress(item.id)
        case .video(let video): video.progress
        }
    }
}

/// Home's hero: the latest thing in progress, with the rest of Continue
/// watching beside it. Nothing in progress has no hero.
public struct HomeHero: Sendable {
    public let hero: Resumable
    public let alsoInProgress: [Resumable]

    /// `progress` is Continue watching, latest played first.
    public init?(_ progress: [Resumable]) {
        guard let first = progress.first else { return nil }
        hero = first
        alsoInProgress = Array(progress.dropFirst())
    }
}

extension YouTubeVideo {
    /// How far through its resume position is; nil with none.
    public var progress: Double? {
        guard positionMs > 0, let durationMs, durationMs > 0 else { return nil }
        return min(1, Double(positionMs) / Double(durationMs))
    }

    /// Home's line under a video: `Workbench Weekly · 23m left`.
    public var resumeLine: String {
        "\(channelTitle) · \(Format.remaining(ms: max(0, (durationMs ?? 0) - positionMs)))"
    }
}

extension Catalog {
    /// Continue watching with `videos` merged in, latest played first.
    public func continueWatching(with videos: [YouTubeVideo]) -> [Resumable] {
        let items = continueWatching.map { (Resumable.item($0), watch[$0.id]?.lastPlayedAt) }
        return (items + videos.map { (.video($0), $0.lastPlayedAt) })
            .sorted { ($0.1 ?? .distantPast) > ($1.1 ?? .distantPast) }.map(\.0)
    }
}

extension Item {
    /// A video as the player's item. The player sends only the id and shows
    /// the title, so a video stands in as a movie there; nothing else may
    /// read its kind.
    public init(video: YouTubeVideo) {
        self.init(
            id: video.id, libraryId: video.libraryId, kind: .movie, parsedTitle: video.title,
            metadata: .init(
                status: .matched, title: video.title, overview: video.overview,
                runtimeMinutes: video.durationMs.map { Int(($0 + 30_000) / 60_000) }),
            addedAt: video.addedAt, updatedAt: video.addedAt)
    }
}

extension Format {
    /// When a video came out, as the boards say it: `today`, `3 days ago`, `last month`.
    /// `day` is the API's calendar date; a future or unreadable one reads today or nothing.
    public static func published(_ day: String, now: Date = .now, calendar: Calendar = .current) -> String {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
            let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
            let days = calendar.dateComponents([.day], from: date, to: calendar.startOfDay(for: now)).day
        else { return "" }
        func ago(_ count: Int, _ unit: String) -> String { count == 1 ? "last \(unit)" : "\(count) \(unit)s ago" }
        switch days {
        case ..<1: return "today"
        case 1: return "yesterday"
        case 2..<7: return "\(days) days ago"
        case 7..<30: return ago(days / 7, "week")
        case 30..<365: return ago(days / 30, "month")
        default: return ago(days / 365, "year")
        }
    }

    /// A video's caption under its thumbnail: `42m · today`.
    public static func video(_ video: YouTubeVideo, now: Date = .now, calendar: Calendar = .current) -> String {
        [
            video.durationMs.map { runtime(minutes: Int(($0 + 30_000) / 60_000)) },
            video.publishedOn.map { published($0, now: now, calendar: calendar) },
        ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
