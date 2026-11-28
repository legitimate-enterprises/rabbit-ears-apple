import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

struct VideoScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(Browser.self) private var browser
    @Environment(CatalogModel.self) private var catalog
    let id: UID
    @State private var detail: VideoDetail?
    @State private var failed = false
    @State private var media: MediaSummary?
    @State private var verdict: Components.Schemas.Verdict?
    @State private var together: WatchTogetherModel?
    let capabilities: SystemCapabilities

    var body: some View {
        Group {
            if let detail {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header(detail.video)
                        details(detail.video)
                        if !detail.moreFromChannel.isEmpty {
                            Heading(text: "More from \(detail.video.channelTitle)")
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(alignment: .top, spacing: 14) {
                                    ForEach(detail.moreFromChannel, id: \.id) {
                                        VideoTile(video: $0, showsChannel: false).frame(width: 180)
                                    }
                                }
                            }
                        }
                    }
                    .padding(EdgeInsets(top: 18, leading: 22, bottom: 24, trailing: 22))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .pageTitle(detail.video.title)
            } else if failed {
                ContentUnavailableView("Not available", systemImage: "questionmark.square.dashed")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(id)/\(browser.revision)") {
            detail = try? await app.youtubeModel?.video(id)
            failed = detail == nil
        }
        .task(id: id) {
            let page = try? await catalog.client.listMediaFiles(query: .init(itemId: id)).ok.body.json
            media = page?.items.first.map(MediaSummary.init)
            if let endpoint = app.endpoint {
                verdict = await catalog.playability(id, facts: capabilities.facts(), server: endpoint)?.verdict
            }
        }
        .watchTogether(itemId: id, model: $together) { position, model in
            if let video = detail?.video { browser.play(video, from: position, together: model) }
        }
    }

    private func header(_ video: YouTubeVideo) -> some View {
        let inProgress = video.positionMs > 0
        return HStack(alignment: .top, spacing: 24) {
            Art(id: video.id, aspect: 16 / 9, radius: 10, placeholder: .video).frame(width: 360)
                .overlay(alignment: .bottom) {
                    if let progress = video.progress { ProgressBar(value: progress, height: 4) }
                }
            VStack(alignment: .leading, spacing: 14) {
                Button {
                    browser.open(.channel(video.channelId))
                } label: {
                    HStack(spacing: 8) {
                        Art(id: video.channelId, circle: true, placeholder: .channel).frame(width: 22)
                        Text(video.channelTitle).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.amber)
                    }
                }
                .buttonStyle(.plain)
                Text(video.title).font(.system(size: 26, weight: .bold))
                MetaLine(
                    parts: [
                        video.durationMs.map { Format.runtime(minutes: Int(($0 + 30_000) / 60_000)) } ?? "",
                        video.publishedOn.flatMap(Self.date) ?? "",
                    ], tags: video.height.map { [Format.resolution(height: $0)] } ?? [],
                    left: inProgress ? Format.remaining(ms: max(0, (video.durationMs ?? 0) - video.positionMs)) : nil)
                if let verdict { PlayabilityLine(verdict: verdict) }
                buttons(video, inProgress: inProgress)
                TogetherHint(together: together, title: video.title)
                if let overview = video.overview {
                    Text(overview).font(.system(size: 13)).foregroundStyle(Theme.synopsis)
                        .frame(maxWidth: 560, alignment: .leading)
                }
            }
        }
    }

    private func buttons(_ video: YouTubeVideo, inProgress: Bool) -> some View {
        HStack(spacing: 10) {
            Button {
                if let together, together.inSync {
                    Task { await together.playTogether() }
                } else {
                    browser.play(video, together: together)
                }
            } label: {
                Label(playTitle(video, inProgress), systemImage: "play.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
            Button {
                Task {
                    await catalog.setWatched(!video.watched, for: Item(video: video))
                    browser.revision += 1
                }
            } label: {
                Label(video.watched ? "Mark unwatched" : "Mark watched", systemImage: "checkmark")
            }
            .buttonStyle(SecondaryButtonStyle())
            FavoriteButton(id: video.id)
            TogetherControl(together: together)
            DownloadButton(target: .video(video))
        }
    }

    private func playTitle(_ video: YouTubeVideo, _ inProgress: Bool) -> String {
        if together?.inSync == true { return "Play together" }
        return inProgress ? "Resume" : "Play"
    }

    private func details(_ video: YouTubeVideo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Heading(text: "Details")
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                if let media, !media.file.chapters.isEmpty {
                    KeyValue(key: "Chapters", value: "\(media.file.chapters.count)")
                }
                if let media, !media.subtitles.isEmpty { KeyValue(key: "Subtitles", value: media.subtitleLine) }
                if let line = media?.videoLine { KeyValue(key: "Video", value: line) }
                KeyValue(key: "Added", value: Self.added(video.addedAt))
                if let source = video.sourceUrl.flatMap(URL.init(string:)) {
                    GridRow {
                        Text("Source").foregroundStyle(Theme.secondary).gridColumnAlignment(.leading)
                        Link("Open on YouTube", destination: source).foregroundStyle(Theme.synopsis)
                    }
                    .font(.system(size: 13))
                }
            }
        }
    }

    /// `Nov 5, 2026` from the API's calendar date.
    private static func date(_ day: String) -> String? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
            let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return nil }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    /// `Today, 6:12 AM`, or the date for an older one.
    private static func added(_ date: Date) -> String {
        let time = date.formatted(.dateTime.hour().minute())
        if Calendar.current.isDateInToday(date) { return "Today, \(time)" }
        return "\(date.formatted(.dateTime.month(.abbreviated).day().year())), \(time)"
    }
}
