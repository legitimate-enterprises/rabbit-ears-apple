import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

struct ChannelView: View {
    @Environment(Services.self) private var services
    @Environment(Browser.self) private var browser
    @Environment(CatalogModel.self) private var catalog
    @Environment(AppModel.self) private var app
    let id: UID
    @State private var detail: ChannelDetail?
    @State private var failure: String?
    @State private var allowed: Set<Account.ID> = []

    var body: some View {
        ScrollView {
            if let detail {
                content(detail)
            } else if let failure {
                ErrorNote(text: failure) { Task { await load() } }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(60)
            }
        }
        .pulling { await load() }
        .background(Theme.ground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            MoreToolbar {
                if let channel = detail?.channel { DownloadMenu(.channel(channel)) }
            }
        }
        // Again when a player closes, since what was watched has changed.
        .task(id: "\(id)/\(browser.playing?.id.uuidString ?? "")") { await load() }
        .task(id: id) { if adult { allowed = await AllowedForKids.load(id, app) } }
    }

    private var adult: Bool { app.activeProfile?.kind == .adult }

    private func load() async {
        do {
            detail = try await services.youtube.channel(id)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    private func content(_ detail: ChannelDetail) -> some View {
        let channel = detail.channel
        let allWatched = channel.unwatchedCount == 0
        return VStack(alignment: .leading, spacing: 22) {
            VStack(spacing: 14) {
                ArtSquare(id: channel.id, round: true, placeholder: .channel).frame(width: 130)
                VStack(spacing: 6) {
                    Text(channel.title).font(.system(size: 26, weight: .bold)).multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { meta(channel) }
                        VStack(spacing: 4) { meta(channel) }
                    }
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                HStack(spacing: 10) {
                    if let newest = detail.videos.first {
                        Button {
                            browser.play(Item(video: newest), in: catalog.catalog)
                        } label: {
                            Label("Play newest", systemImage: "play.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PrimaryButtonStyle(fullWidth: true))
                    }
                    Button {
                        Task {
                            try? await services.youtube.setWatched(allWatched ? false : true, channel: channel.id)
                            await load()
                        }
                    } label: {
                        Label(allWatched ? "Mark all unwatched" : "Mark all watched", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryButtonStyle(fullWidth: true))
                }
                if adult { kidsRules(channel) }
                if let overview = channel.overview, !overview.isEmpty {
                    Text(overview).font(.system(size: 14)).foregroundStyle(Theme.synopsis)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Videos").font(.system(size: 17, weight: .bold))
                LazyVGrid(columns: VideosGrid.columns, spacing: 14) {
                    ForEach(detail.videos, id: \.id) { VideoTile(video: $0, caption: .age) }
                }
            }
        }
        .padding(EdgeInsets(top: 4, leading: 16, bottom: 20, trailing: 16))
    }

    /// For kids lets kids under rating ceilings see the channel; a kid on a list needs it on their list.
    private func kidsRules(_ channel: YouTubeChannel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(
                "For kids",
                isOn: Binding(
                    get: { channel.forKids == true },
                    set: { on in
                        Task {
                            try? await services.youtube.setForKids(on, channel: channel.id)
                            await load()
                        }
                    }))
            if !app.allowListKids.isEmpty {
                Text("Allowed for kids on a list").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                AllowedForKids(itemId: channel.id, allowed: $allowed)
            }
        }
        .font(.system(size: 15)).tint(Theme.amber)
        .padding(14).background(Theme.raised, in: .rect(cornerRadius: 10))
    }

    @ViewBuilder
    private func meta(_ channel: YouTubeChannel) -> some View {
        Text(channel.videoCount == 1 ? "1 video" : "\(channel.videoCount) videos")
        Text("\(channel.unwatchedCount) unwatched")
        if let last = channel.lastVideoOn { Text("Last video \(Format.published(last))") }
    }
}

struct VideoView: View {
    @Environment(Services.self) private var services
    @Environment(Browser.self) private var browser
    @Environment(CatalogModel.self) private var catalog
    @Environment(AppModel.self) private var app
    let id: UID
    @State private var detail: VideoDetail?
    @State private var failure: String?
    @State private var media: MediaSummary?
    @State private var verdict: Components.Schemas.Verdict?
    private let capabilities = AppContext.shared.capabilities
    @State private var together: WatchTogetherModel?

    var body: some View {
        ScrollView {
            if let detail {
                content(detail)
            } else if let failure {
                ErrorNote(text: failure) { Task { await load() } }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(60)
            }
        }
        .background(Theme.ground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            MoreToolbar {
                if let video = detail?.video {
                    Button("Go to channel", systemImage: "play.rectangle") { browser.open(.channel(video.channelId)) }
                    DownloadMenu(.video(video))
                }
            }
        }
        // Again when a player closes, since the position and watched mark have changed.
        .task(id: "\(id)/\(browser.playing?.id.uuidString ?? "")") { await load() }
        .task(id: id) { await watch() }
        .task(id: id) { await probe() }
    }

    private func load() async {
        do {
            detail = try await services.youtube.video(id)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    private func probe() async {
        let page = try? await catalog.client.listMediaFiles(query: .init(itemId: id)).ok.body.json
        media = page?.items.first.map(MediaSummary.init)
        if let endpoint = app.endpoint {
            verdict = await catalog.playability(id, facts: capabilities.facts(), server: endpoint)?.verdict
        }
    }

    private func watch() async {
        guard let model = app.watchTogether(itemId: id) else { return }
        let (catalogModel, browser, services) = (catalog, browser, services)
        model.onStart = { [weak model] ms in
            guard let model else { return }
            Task {
                guard let video = try? await services.youtube.video(model.itemId).video else { return }
                browser.play(Item(video: video), in: catalogModel.catalog, from: ms, together: model)
            }
        }
        together = model
        await model.run()
    }

    private func content(_ detail: VideoDetail) -> some View {
        let video = detail.video
        return VStack(alignment: .leading, spacing: 22) {
            header(video)
            details(video)
            if !detail.moreFromChannel.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("More from \(video.channelTitle)").font(.system(size: 17, weight: .bold))
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(detail.moreFromChannel, id: \.id) {
                                VideoTile(video: $0, caption: .age).frame(width: 170)
                            }
                        }
                    }
                }
            }
        }
        .padding(EdgeInsets(top: 4, leading: 16, bottom: 20, trailing: 16))
    }

    private func header(_ video: YouTubeVideo) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ArtSquare(id: video.id, aspect: 16 / 9, radius: 10, placeholder: .video)
                .overlay(alignment: .bottom) {
                    if let progress = video.progress { ProgressBar(value: progress, height: 4) }
                }
            Button {
                browser.open(.channel(video.channelId))
            } label: {
                HStack(spacing: 8) {
                    ArtSquare(id: video.channelId, round: true, placeholder: .channel).frame(width: 24)
                    Text(video.channelTitle).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.amber)
                }
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 6) {
                Text(video.title).font(.system(size: 24, weight: .bold)).accessibilityAddTraits(.isHeader)
                HStack(spacing: 10) {
                    if let ms = video.durationMs { Text(Format.runtime(minutes: Int((ms + 30_000) / 60_000))) }
                    if let day = video.publishedOn { Text(Self.date(day)) }
                    ForEach(media?.tags ?? [], id: \.self) { Tag(text: $0) }
                    if let height = video.height { Tag(text: Format.resolution(height: height)) }
                }
                .font(.system(size: 13)).foregroundStyle(Theme.secondary)
            }
            actions(video)
            if let together { TogetherNotice(model: together, title: video.title) }
            if let overview = video.overview, !overview.isEmpty {
                Text(overview).font(.system(size: 14)).foregroundStyle(Theme.synopsis)
            }
        }
    }

    private func resuming(_ video: YouTubeVideo) -> Bool { video.positionMs > 0 }

    private func actions(_ video: YouTubeVideo) -> some View {
        let stand = Item(video: video)
        let shared = together?.inSync == true ? together : nil
        return HStack(spacing: 10) {
            Button {
                if let shared {
                    Task { await shared.playTogether() }
                } else {
                    browser.play(stand, in: catalog.catalog)
                }
            } label: {
                Label(shared != nil ? "Play together" : resuming(video) ? "Resume" : "Play", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle(fullWidth: true))
            Button {
                Task {
                    await catalog.setWatched(!video.watched, for: stand)
                    await load()
                }
            } label: {
                Label(video.watched ? "Unwatched" : "Watched", systemImage: "checkmark")
            }
            .buttonStyle(SecondaryButtonStyle(fullWidth: true))
            .accessibilityLabel(video.watched ? "Mark unwatched" : "Mark watched")
            if let together { TogetherButton(model: together) }
        }
    }

    @ViewBuilder
    private func details(_ video: YouTubeVideo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Details").font(.system(size: 17, weight: .bold))
            if let media {
                if !media.file.chapters.isEmpty { KeyValue(key: "Chapters", value: "\(media.file.chapters.count)") }
                if !media.subtitles.isEmpty { KeyValue(key: "Subtitles", value: media.subtitleLine) }
                if let line = media.videoLine {
                    KeyValue(key: "Video") {
                        if let verdict {
                            let label = Text(Format.verdict(verdict))
                                .foregroundStyle(verdict == .directPlay ? Theme.green : Theme.amber)
                            Text("\(line) · \(label)")
                        } else {
                            Text(line)
                        }
                    }
                }
            }
            KeyValue(key: "Added", value: video.addedAt.formatted(date: .abbreviated, time: .shortened))
        }
    }

    /// `2026-11-05` as `Nov 5, 2026`.
    static func date(_ day: String) -> String {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
            let date = Calendar.current.date(from: .init(year: parts[0], month: parts[1], day: parts[2]))
        else { return day }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
