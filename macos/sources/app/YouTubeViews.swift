import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

extension YouTubeChannelSort {
    var title: String {
        switch self {
        case .title: "Title"
        case .latest: "Latest video"
        }
    }
}

struct YouTubeScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(Browser.self) private var browser
    let search: String
    @AppStorage("youtube.tab") private var tab = YouTubeTab.videos
    @AppStorage("youtube.sort") private var sort = YouTubeVideoSort.newest
    @AppStorage("youtube.channelSort") private var channelSort = YouTubeChannelSort.title
    @State private var channel: UID?
    @State private var channels: [YouTubeChannel] = []
    @State private var videos: Pager<YouTubeVideo>?
    @State private var selection = Selection()

    private var shown: YouTubeTab { search.isEmpty ? tab : .videos }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ViewTabs(
                    options: YouTubeTab.tabs, label: \.rawValue,
                    selection: Binding(get: { tab.tab }, set: { if $0 != tab.tab { tab = $0 } }))
                HStack(spacing: 8) {
                    if shown != .channels {
                        Chips(
                            options: [YouTubeTab.unwatched], label: \.rawValue,
                            selection: Binding(get: { tab }, set: { tab = $0 == tab ? .videos : $0 }))
                        DownloadedChip()
                    }
                    Spacer()
                    if shown == .channels {
                        Picker("Sort", selection: $channelSort) {
                            ForEach(YouTubeChannelSort.allCases, id: \.self) { Text($0.title) }
                        }
                        .fixedSize()
                    } else {
                        Picker("Sort", selection: $sort) {
                            ForEach(YouTubeVideoSort.allCases, id: \.self) { Text($0.title) }
                        }
                        .fixedSize()
                        Picker("Channel", selection: $channel) {
                            Text("Any").tag(UID?.none)
                            ForEach(channels, id: \.id) { Text($0.title).tag(Optional($0.id)) }
                        }
                        .fixedSize()
                    }
                    SelectButton(selection: selection, kind: shown == .channels ? .channel : .video)
                }
                switch shown {
                case .videos, .unwatched: videoGrid
                case .channels: channelGrid
                }
            }
            .padding(EdgeInsets(top: 10, leading: 22, bottom: 24, trailing: 22))
        }
        .selectionBar(
            selection, shown == .channels ? .channel : .video,
            order: shown == .channels ? channels.map(\.id) : (videos?.items ?? []).map(\.id)
        )
        .onChange(of: shown) { selection.end() }
        .navigationSubtitle("\(channels.count) channels")
        .task(id: "\(channelSort.rawValue)/\(browser.revision)") {
            channels = (try? await app.youtubeModel?.channels(sort: channelSort)) ?? []
        }
        .task(id: "\(shown.rawValue)/\(sort.rawValue)/\(channel?.description ?? "")/\(search)/\(downloadedOnly)") {
            await load()
        }
        // A watch-state change refreshes the rows in place; the scroll position stays.
        .task(id: browser.revision) { await videos?.refresh() }
    }

    private var downloadedOnly: Bool { app.downloads?.downloadedOnly == true }

    private var videoGrid: some View {
        let loaded = videos?.items ?? []
        return VStack(alignment: .leading, spacing: 16) {
            if videos?.done == true && loaded.isEmpty {
                Text(downloadedOnly ? "Nothing downloaded here yet." : "No videos match.")
                    .foregroundStyle(Theme.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16, alignment: .top)], spacing: 18) {
                ForEach(loaded, id: \.id) { video in
                    VideoTile(video: video)
                        .selectable(selection, video.id, in: loaded.map(\.id))
                        .onAppear { if video.id == loaded.last?.id { Task { await videos?.loadMore() } } }
                }
            }
        }
    }

    private var channelGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 16, alignment: .top)], spacing: 18) {
            let order = channels.map(\.id)
            ForEach(channels, id: \.id) { ChannelTile(channel: $0).selectable(selection, $0.id, in: order) }
        }
    }

    private func load() async {
        guard let youtube = app.youtubeModel else { return }
        if !search.isEmpty {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
        }
        let (sort, channel, search, unwatched, onDevice) = (
            sort, channel, search, shown == .unwatched, app.downloadedFilter
        )
        switch shown {
        case .videos, .unwatched:
            let pager = Pager { offset in
                let page = try await youtube.videos(
                    sort: sort, channelId: channel, unwatched: unwatched, onDevice: onDevice,
                    query: search.isEmpty ? nil : search, offset: offset, limit: 100)
                return (page.items, page.nextOffset)
            }
            await pager.loadMore()
            videos = pager
        case .channels: break
        }
    }
}

struct VideoTile: View {
    @Environment(Browser.self) private var browser
    let video: YouTubeVideo
    var showsChannel = true

    var body: some View {
        Button {
            browser.open(.video(video.id))
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                let progress = video.progress
                Art(
                    id: video.id, aspect: 16 / 9, placeholder: .video,
                    badges: StatusBadges(id: video.id, overBar: progress != nil)
                )
                .overlay(alignment: .topTrailing) { Self.dot(video) }
                .overlay(alignment: .bottom) {
                    if let progress { ProgressBar(value: progress).padding(6) }
                }
                Text(video.title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                Text(caption).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(2)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu { VideoContextMenu(video: video) }
    }

    private var caption: String {
        [showsChannel ? video.channelTitle : "", Format.video(video)].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func dot(_ video: YouTubeVideo) -> some View {
        Circle().fill(video.watched ? .clear : Theme.amber).frame(width: 10, height: 10)
            .overlay(Circle().stroke(video.watched ? .clear : .black.opacity(0.35), lineWidth: 2)).padding(8)
            .accessibilityLabel(video.watched ? "" : "Unwatched")
    }
}

struct VideoStrip: View {
    let title: String
    let videos: [YouTubeVideo]

    var body: some View {
        if !videos.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Heading(text: title)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(videos, id: \.id) { VideoTile(video: $0).frame(width: 224) }
                    }
                }
            }
        }
    }
}

struct InProgressVideoRow: View {
    @Environment(Browser.self) private var browser
    let video: YouTubeVideo

    var body: some View {
        Button {
            browser.play(video)
        } label: {
            HStack(spacing: 10) {
                Art(id: video.id, aspect: 16 / 9, radius: 4, placeholder: .video).frame(width: 88)
                VStack(alignment: .leading, spacing: 2) {
                    Text(video.channelTitle).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text("\(video.title) · \(left)").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                    if let progress = video.progress { ProgressBar(value: progress).padding(.top, 4) }
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu { VideoContextMenu(video: video) }
    }

    private var left: String { Format.remaining(ms: max(0, (video.durationMs ?? 0) - video.positionMs)) }
}

struct ChannelTile: View {
    @Environment(Browser.self) private var browser
    let channel: YouTubeChannel

    var body: some View {
        Button {
            browser.open(.channel(channel.id))
        } label: {
            VStack(spacing: 6) {
                Art(id: channel.id, circle: true, placeholder: .channel).frame(width: 110)
                Text(channel.title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                Text(
                    channel.unwatchedCount > 0
                        ? "\(channel.videoCount) videos · \(channel.unwatchedCount) new"
                        : "\(channel.videoCount) videos"
                )
                .font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
            .multilineTextAlignment(.center).frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
