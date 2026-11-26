import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

struct VideoDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(CatalogModel.self) private var catalog
    @Environment(Browser.self) private var browser
    let id: Int64
    @State private var detail: VideoDetail?
    @State private var loaded = false
    @State private var verdict: Components.Schemas.Verdict?
    @State private var media: MediaSummary?
    @State private var together: WatchTogetherModel?
    let capabilities: SystemCapabilities

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 50) {
                if let detail {
                    header(detail.video)
                    if !detail.moreFromChannel.isEmpty {
                        VideoGrid(
                            title: "More from \(detail.video.channelTitle)", videos: detail.moreFromChannel,
                            showsChannel: false)
                    }
                } else if loaded {
                    Text("Not available").font(.system(size: 34)).foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity).padding(80)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(80)
                }
            }
            .padding(Theme.safeArea)
        }
        .scrollClipDisabled()
        .background(Theme.ground)
        .ignoresSafeArea()
        .toolbar(.hidden, for: .navigationBar)
        .task(id: "\(id)/\(browser.returns)") {
            detail = try? await app.youTubeModel?.video(id)
            loaded = true
            let page = try? await catalog.client.listMediaFiles(query: .init(itemId: id)).ok.body.json
            media = page?.items.first.map(MediaSummary.init)
            if let endpoint = app.endpoint {
                verdict = await catalog.playability(id, facts: capabilities.facts(), server: endpoint)?.verdict
            }
        }
        .task(id: id) {
            guard let session = app.watchTogether(itemId: id) else { return }
            session.onStart = { [weak session] ms in
                if let session, let video = detail?.video { browser.play(video, from: ms, together: session) }
            }
            together = session
            await session.run()
        }
    }

    private func header(_ video: YouTubeVideo) -> some View {
        let started = video.positionMs > 0
        let synced = together?.inSync == true
        return HStack(alignment: .top, spacing: 56) {
            ArtBlock(id: video.id, aspect: 16 / 9, radius: 16, placeholder: .video).frame(width: 640)
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    browser.open(.channel(video.channelId))
                } label: {
                    HStack(spacing: 16) {
                        ArtBlock(id: video.channelId, radius: 18, placeholder: .channel).frame(width: 36)
                        Text(video.channelTitle).font(.system(size: 30, weight: .semibold)).foregroundStyle(Theme.amber)
                    }
                }
                .buttonStyle(CardButtonStyle(scale: 1.04))
                Text(video.title).font(.system(size: 80, weight: .bold)).lineLimit(2).minimumScaleFactor(0.6).padding(
                    .top, 8)
                MetaLine(
                    parts: [
                        video.durationMs.map { Format.runtime(minutes: Int(($0 + 30_000) / 60_000)) } ?? "",
                        DateText.day(video.publishedOn),
                    ], tags: video.height.map { ["\($0)p"] } ?? []
                )
                .padding(.top, 12)
                actions(video, started: started, synced: synced)
                    .padding(.top, 32)
                    .focusSection()
                if let together { TogetherNote(together: together, title: video.title) }
                if let overview = video.overview {
                    Text(overview).font(.system(size: 28)).foregroundStyle(Theme.synopsis).lineLimit(4).padding(
                        .top, 30)
                }
                VStack(alignment: .leading, spacing: 12) {
                    if let media, !media.file.chapters.isEmpty {
                        KeyValue(key: "Chapters", value: "\(media.file.chapters.count)")
                    }
                    if let media, !media.subtitles.isEmpty {
                        KeyValue(key: "Subtitles", value: media.subtitleLine)
                    }
                    if let height = video.height {
                        KeyValue(key: "Video") {
                            if let verdict {
                                let label = Text(Format.verdict(verdict)).bold()
                                    .foregroundColor(verdict == .directPlay ? Theme.green : Theme.amber)
                                Text("\(height)p · \(label) on this device")
                            } else {
                                Text("\(height)p")
                            }
                        }
                    }
                }
                .padding(.top, 30)
            }
        }
    }

    private func actions(_ video: YouTubeVideo, started: Bool, synced: Bool) -> some View {
        HStack(spacing: 24) {
            Button {
                if synced, let together {
                    Task { await together.playTogether() }
                } else {
                    browser.play(video, together: together)
                }
            } label: {
                Label(synced ? "Play together" : started ? "Resume" : "Play", systemImage: "play.fill")
            }
            .buttonStyle(TVButtonStyle(primary: true))
            Button {
                Task {
                    await catalog.setWatched(!video.watched, for: Item(video: video))
                    detail = try? await app.youTubeModel?.video(id)
                }
            } label: {
                Label(video.watched ? "Mark unwatched" : "Mark watched", systemImage: "checkmark")
            }
            .buttonStyle(TVButtonStyle())
            if let together { TogetherButtons(together: together) }
        }
    }
}
