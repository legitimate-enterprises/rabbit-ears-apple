import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

let videoColumns = Array(repeating: GridItem(.fixed(410), spacing: 40, alignment: .top), count: 4)

struct YouTubeScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(Browser.self) private var browser
    @AppStorage("youtube.chip") private var tab = YouTubeTab.videos
    @AppStorage("youtube.sort") private var sort = YouTubeVideoSort.newest
    @State private var channel: UID?
    @State private var board: YouTubeBoard?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 44) {
                ViewTabs(
                    options: YouTubeTab.tabs, label: \.rawValue,
                    selection: Binding(get: { tab.tab }, set: { if $0 != tab.tab { tab = $0 } }))
                HStack(spacing: 16) {
                    if tab != .channels {
                        Button("Unwatched") { tab = tab == .unwatched ? .videos : .unwatched }
                            .buttonStyle(ChipStyle(selected: tab == .unwatched))
                    }
                    Text(board?.caption ?? "").font(.system(size: 30)).foregroundStyle(Theme.secondary)
                        .padding(.leading, tab != .channels ? 16 : 0)
                    Spacer()
                    if tab == .videos || tab == .unwatched {
                        Menu {
                            Picker("Sort", selection: $sort) {
                                ForEach(YouTubeVideoSort.allCases, id: \.self) { Text($0.title) }
                            }
                        } label: {
                            MenuLabel(key: "Sort", value: sort.title)
                        }
                    }
                    if tab == .videos || tab == .unwatched, let channels = board?.channels, !channels.isEmpty {
                        Menu {
                            Picker("Channel", selection: $channel) {
                                Text("Any").tag(UID?.none)
                                ForEach(channels, id: \.id) { Text($0.title).tag(Optional($0.id)) }
                            }
                        } label: {
                            MenuLabel(key: "Channel", value: channels.first { $0.id == channel }?.title ?? "Any")
                        }
                    }
                }
                .buttonStyle(ChipStyle(selected: false, radius: 12))
                .focusSection()
                content
            }
            .padding(EdgeInsets(top: shellTop + 8, leading: 80, bottom: 60, trailing: 80))
        }
        .scrollClipDisabled()
        .task(id: "\(tab.rawValue)/\(sort.rawValue)/\(channel?.description ?? "")") {
            guard let model = app.youTubeModel else { return }
            let board = board ?? YouTubeBoard(youTube: model)
            if self.board == nil {
                self.board = board
                Task { await board.loadChannels() }
            }
            await board.load(tab, sort: sort, channel: channel)
        }
        // Returning from the player refreshes the rows in place; the focused tile stays.
        .task(id: browser.returns) { await board?.refresh(tab) }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .videos, .unwatched:
            let videos = board?.videos?.items ?? []
            if board?.videos?.done == true && videos.isEmpty {
                Text(tab == .unwatched ? "Nothing unwatched." : "No videos yet.").font(.system(size: 30))
                    .foregroundStyle(Theme.secondary).frame(maxWidth: .infinity).padding(80)
            }
            LazyVGrid(columns: videoColumns, alignment: .leading, spacing: 50) {
                ForEach(Array(videos.enumerated()), id: \.element.id) { index, video in
                    VideoTile(video: video)
                        .onAppear { if index >= videos.count - 8 { Task { await board?.videos?.loadMore() } } }
                }
            }
            .focusSection()
        case .channels:
            LazyVGrid(columns: GridView.columns, alignment: .leading, spacing: 50) {
                ForEach(board?.channels ?? [], id: \.id) { ChannelTile(channel: $0) }
            }
            .focusSection()
        }
    }
}

struct VideoTile: View {
    @Environment(Browser.self) private var browser
    let video: YouTubeVideo
    /// A channel's own screen leaves its name out of every tile.
    var showsChannel = true

    var body: some View {
        Button {
            browser.open(.video(video.id))
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                ArtBlock(id: video.id, aspect: 16 / 9, placeholder: .video)
                    .overlay(alignment: .topTrailing) {
                        if !video.watched {
                            Circle().fill(Theme.amber).frame(width: 22, height: 22)
                                .overlay(Circle().stroke(.black.opacity(0.35), lineWidth: 3)).padding(14)
                                .accessibilityLabel("Unwatched")
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if video.positionMs > 0, let total = video.durationMs, total > 0 {
                            ProgressBar(value: min(1, Double(video.positionMs) / Double(total))).padding(14)
                        }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(video.title).font(.system(size: 28, weight: .semibold)).lineLimit(1)
                    if showsChannel {
                        Text(video.channelTitle).font(.system(size: 26)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(Format.video(video)).font(.system(size: 26)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .buttonStyle(CardButtonStyle())
        .contextMenu { VideoContextMenu(video: video) }
    }
}

struct ChannelTile: View {
    @Environment(Browser.self) private var browser
    let channel: YouTubeChannel

    var body: some View {
        Button {
            browser.open(.channel(channel.id))
        } label: {
            VStack(spacing: 14) {
                ArtBlock(id: channel.id, radius: 130, placeholder: .channel).frame(width: 220)
                Text(channel.title).font(.system(size: 28, weight: .semibold)).lineLimit(1)
                Text(
                    channel.unwatchedCount > 0 ? "\(channel.unwatchedCount) unwatched" : "\(channel.videoCount) videos"
                )
                .font(.system(size: 26)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(CardButtonStyle())
    }
}

struct ChannelView: View {
    @Environment(AppModel.self) private var app
    @Environment(Browser.self) private var browser
    let id: UID
    @State private var detail: ChannelDetail?
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 50) {
                if let detail {
                    header(detail)
                    VideoGrid(title: "Videos", videos: detail.videos, showsChannel: false)
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
            detail = try? await app.youTubeModel?.channel(id)
            loaded = true
        }
    }

    private func header(_ detail: ChannelDetail) -> some View {
        let channel = detail.channel
        return HStack(alignment: .top, spacing: 48) {
            ArtBlock(id: channel.id, radius: 120, placeholder: .channel).frame(width: 240)
            VStack(alignment: .leading, spacing: 0) {
                Text(channel.title).font(.system(size: 80, weight: .bold)).lineLimit(1).minimumScaleFactor(0.5)
                MetaLine(
                    parts: [
                        Format.count(channel.videoCount, "video"),
                        "\(channel.unwatchedCount) unwatched",
                        channel.lastVideoOn.map { "Last video \(Format.published($0))" } ?? "",
                    ]
                )
                .padding(.top, 4)
                HStack(spacing: 24) {
                    if let newest = detail.videos.first {
                        Button {
                            browser.play(newest)
                        } label: {
                            Label("Play newest", systemImage: "play.fill")
                        }
                        .buttonStyle(TVButtonStyle(primary: true))
                    }
                    Button {
                        Task {
                            try? await app.youTubeModel?.setWatched(channel.unwatchedCount > 0, channel: channel.id)
                            self.detail = try? await app.youTubeModel?.channel(id)
                        }
                    } label: {
                        Label(
                            channel.unwatchedCount == 0 ? "Mark all unwatched" : "Mark all watched",
                            systemImage: "checkmark")
                    }
                    .buttonStyle(TVButtonStyle())
                }
                .padding(.top, 28)
                .focusSection()
                if let overview = channel.overview {
                    Text(overview).font(.system(size: 28)).foregroundStyle(Theme.synopsis).lineLimit(3).padding(
                        .top, 28)
                }
            }
        }
    }
}

struct VideoGrid: View {
    let title: String
    let videos: [YouTubeVideo]
    var showsChannel = true

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(title).font(.system(size: 34, weight: .bold))
            LazyVGrid(columns: videoColumns, alignment: .leading, spacing: 50) {
                ForEach(videos, id: \.id) { VideoTile(video: $0, showsChannel: showsChannel) }
            }
        }
        .focusSection()
    }
}

extension Browser {
    /// The player knows a YouTube video as a movie.
    func play(_ video: YouTubeVideo, from positionMs: Int64? = nil, together: WatchTogetherModel? = nil) {
        guard together == nil || !watchesTogether(video.id) else { return }
        playing = PlayRequest(item: Item(video: video), positionMs: positionMs, together: together)
    }
}
