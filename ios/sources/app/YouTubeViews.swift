import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

struct YouTubeView: View {
    @Environment(Services.self) private var services
    @State private var tab = YouTubeTab.videos
    @State private var channels: [YouTubeChannel]?
    @State private var selection = Selection()
    @Environment(Browser.self) private var browser
    @State private var reloader = Reloader()
    @AppStorage("youtube.videoSort") private var sort = YouTubeVideoSort.newest

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ViewTabs(
                    options: YouTubeTab.tabs, title: \.rawValue,
                    selection: Binding(get: { tab.tab }, set: { if $0 != tab.tab { tab = $0 } }))
                if tab != .channels {
                    ChipBar(
                        options: [YouTubeTab.unwatched], title: \.rawValue,
                        selection: Binding(get: { tab }, set: { tab = $0 == tab ? .videos : $0 }))
                }
                switch tab {
                case .videos: VideosGrid(sort: sort, unwatched: false)
                case .unwatched: VideosGrid(sort: sort, unwatched: true)
                case .channels: ChannelsGrid(channels: channels)
                }
            }
            .padding(EdgeInsets(top: 0, leading: 20, bottom: 20, trailing: 20))
        }
        .countedTitle(LibraryTab.youtube.rawValue, count: channels?.count.formatted() ?? "")
        .toolbar {
            if tab == .videos || tab == .unwatched {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort", selection: $sort) {
                            ForEach(YouTubeVideoSort.allCases, id: \.self) { Text($0.title) }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease")
                    }
                    .accessibilityLabel("Sort")
                }
            }
            BrowseToolbar()
        }
        .environment(reloader)
        .pulling {
            async let reading: Void = loadChannels()
            if tab != .channels { await reloader.action?() }
            await reading
        }
        .selecting(selection, tab == .channels ? .channel : .video)
        .task(id: browser.revision) { await loadChannels() }
    }

    /// Channels the server could not answer stay as shown.
    private func loadChannels() async {
        channels = (try? await services.youtube.channels()) ?? channels
    }
}

struct VideosGrid: View {
    @Environment(Services.self) private var services
    @Environment(Browser.self) private var browser
    let sort: YouTubeVideoSort
    let unwatched: Bool
    var query: String?
    @State private var list: Pager<YouTubeVideo>?

    static let columns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 2)

    var body: some View {
        VStack(spacing: 16) {
            if let list {
                if list.items.isEmpty && list.done { EmptyNote(text: "No videos yet.") }
                LazyVGrid(columns: Self.columns, spacing: 14) {
                    ForEach(list.items, id: \.id) { video in
                        VideoTile(video: video)
                            .selectable(video.id)
                            .onAppear { if video.id == list.items.last?.id { Task { await list.loadMore() } } }
                    }
                }
                if let error = list.error { ErrorNote(text: error) { Task { await list.loadMore() } } }
            } else {
                ProgressView().padding(40)
            }
        }
        .task(id: "\(sort.rawValue)/\(unwatched)/\(query ?? "")") {
            let youtube = services.youtube
            let (sort, unwatched, query) = (sort, unwatched, query)
            // Typing in a search waits for a pause.
            if query != nil { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled else { return }
            let next = Pager<YouTubeVideo> { offset in
                let page = try await youtube.videos(sort: sort, unwatched: unwatched, query: query, offset: offset)
                return (page.items, page.nextOffset)
            }
            list = next
            await next.loadMore()
        }
        // A watch-state change refreshes the rows in place; the scroll position stays.
        .task(id: browser.revision) { await list?.refresh() }
        .reloads { await list?.refresh(reporting: true) }
        .selectingAll(.init({ list }, id: \.id))
    }
}

struct VideoTile: View {
    enum Caption { case channel, age }

    @Environment(Browser.self) private var browser
    let video: YouTubeVideo
    var caption = Caption.channel

    var body: some View {
        Button {
            browser.open(.video(video.id))
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                ArtSquare(id: video.id, aspect: 16 / 9, placeholder: .video)
                    .overlay(alignment: .topTrailing) {
                        if !video.watched {
                            Circle().fill(Theme.amber).frame(width: 10, height: 10)
                                .overlay(Circle().stroke(.black.opacity(0.35), lineWidth: 2)).padding(8)
                                .accessibilityLabel("Unwatched")
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if let progress = video.progress { ProgressBar(value: progress, height: 4) }
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(video.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(line).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu { VideoContextMenu(video: video, selectable: true) }
    }

    private var line: String {
        switch caption {
        case .age: Format.video(video)
        case .channel:
            [video.channelTitle, video.durationMs.map { Format.runtime(minutes: Int(($0 + 30_000) / 60_000)) }]
                .compactMap { $0 }.joined(separator: " · ")
        }
    }
}

/// A video's long-press menu: Select and Play, then what its details offer: watched, its channel and Download.
struct VideoContextMenu: View {
    @Environment(Browser.self) private var browser
    @Environment(CatalogModel.self) private var catalog
    let video: YouTubeVideo
    var selectable = false

    var body: some View {
        if selectable { SelectMenuItem(id: video.id) }
        Button("Play", systemImage: "play.fill") { browser.play(Item(video: video), in: catalog.catalog) }
        Button(video.watched ? "Mark as unwatched" : "Mark as watched", systemImage: "checkmark") {
            Task {
                await catalog.setWatched(!video.watched, for: Item(video: video))
                browser.revision += 1
            }
        }
        Button("Go to channel", systemImage: "play.rectangle") { browser.open(.channel(video.channelId)) }
        FavoriteMenuItem(id: video.id)
        DownloadMenu(.video(video))
    }
}

struct ChannelsGrid: View {
    @Environment(Browser.self) private var browser
    let channels: [YouTubeChannel]?

    var body: some View {
        if let channels {
            if channels.isEmpty { EmptyNote(text: "No channels yet.") }
            LazyVGrid(columns: GridView.columns, spacing: 16) {
                ForEach(channels, id: \.id) { channel in
                    Button {
                        browser.open(.channel(channel.id))
                    } label: {
                        VStack(spacing: 6) {
                            ArtSquare(id: channel.id, round: true, placeholder: .channel)
                            Text(channel.title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                                .multilineTextAlignment(.center)
                            if channel.unwatchedCount > 0 {
                                Text("\(channel.unwatchedCount) new").font(.system(size: 11))
                                    .foregroundStyle(Theme.amber)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { SelectMenuItem(id: channel.id) }
                    .selectable(channel.id)
                }
            }
            .selectingAll(.init { channels.map(\.id) }, token: channels.map(\.id))
        } else {
            ProgressView().padding(40)
        }
    }
}

struct NewFromChannels: View {
    let videos: [YouTubeVideo]

    var body: some View {
        if !videos.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("New from your channels").font(.system(size: 20, weight: .bold))
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(videos, id: \.id) { VideoTile(video: $0).frame(width: 170) }
                    }
                }
                .contentMargins(.horizontal, 20, for: .scrollContent)
                .padding(.horizontal, -20)
            }
        }
    }
}

/// Server search over video titles.
struct YouTubeSearchView: View {
    @State private var search = ""

    var body: some View {
        ScrollView {
            if !query.isEmpty {
                VideosGrid(sort: .newest, unwatched: false, query: query)
                    .padding(EdgeInsets(top: 4, leading: 20, bottom: 20, trailing: 20))
            }
        }
        .frame(maxWidth: .infinity)
        .background(Theme.ground)
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search YouTube")
        .toolbar { BrowseToolbar(search: false) }
    }

    private var query: String { search.trimmingCharacters(in: .whitespaces) }
}
