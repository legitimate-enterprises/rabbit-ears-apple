import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

struct ChannelScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(Browser.self) private var browser
    let id: Int64
    @State private var sort = YouTubeVideoSort.newest
    @State private var detail: ChannelDetail?
    @State private var failed = false
    @State private var allowed: Set<Account.ID> = []

    var body: some View {
        Group {
            if let detail {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header(detail)
                        HStack {
                            Heading(text: "Videos")
                            Spacer()
                            Picker("Sort", selection: $sort) {
                                ForEach(YouTubeVideoSort.allCases, id: \.self) { Text($0.title) }
                            }
                            .fixedSize()
                        }
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 220), spacing: 16, alignment: .top)], spacing: 18
                        ) {
                            ForEach(detail.videos, id: \.id) { VideoTile(video: $0, showsChannel: false) }
                        }
                    }
                    .padding(EdgeInsets(top: 18, leading: 22, bottom: 24, trailing: 22))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .pageTitle(detail.channel.title)
            } else if failed {
                ContentUnavailableView("Not available", systemImage: "questionmark.square.dashed")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(id)/\(sort.rawValue)/\(browser.revision)") {
            detail = try? await app.youtubeModel?.channel(id, sort: sort)
            failed = detail == nil
            allowed = await AllowedForKids.load(id, app)
        }
    }

    /// Any adult says whether the channel is for kids and which kids on a list may watch it.
    @ViewBuilder
    private func kidsRules(_ channel: YouTubeChannel) -> some View {
        if app.isAdult {
            HStack(spacing: 14) {
                Toggle(
                    "For kids",
                    isOn: Binding(
                        get: { channel.forKids == true },
                        set: { on in
                            Task {
                                do { try await app.youtubeModel?.setForKids(on, channel: channel.id) } catch {
                                    app.live.say(error.localizedDescription)
                                }
                                browser.revision += 1
                            }
                        })
                )
                .toggleStyle(.switch).font(.system(size: 13))
                if !app.allowListKids.isEmpty {
                    Menu("Allowed for kids") { AllowedForKids(itemId: channel.id, allowed: $allowed) }
                        .fixedSize()
                }
            }
        }
    }

    private func header(_ detail: ChannelDetail) -> some View {
        let channel = detail.channel
        let newest = detail.videos.max { ($0.publishedOn ?? "") < ($1.publishedOn ?? "") }
        return HStack(alignment: .top, spacing: 24) {
            Art(id: channel.id, circle: true, placeholder: .channel).frame(width: 130)
            VStack(alignment: .leading, spacing: 14) {
                Text(channel.title).font(.system(size: 26, weight: .bold))
                HStack(spacing: 10) {
                    Text("\(channel.videoCount) videos")
                    if channel.unwatchedCount > 0 { Text("\(channel.unwatchedCount) unwatched") }
                    if let last = channel.lastVideoOn { Text("Last video \(Format.published(last))") }
                }
                .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                HStack(spacing: 10) {
                    if let newest {
                        Button {
                            browser.play(newest)
                        } label: {
                            Label("Play newest", systemImage: "play.fill")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }
                    Button {
                        Task {
                            try? await app.youtubeModel?.setWatched(channel.unwatchedCount > 0, channel: channel.id)
                            browser.revision += 1
                        }
                    } label: {
                        Label(
                            channel.unwatchedCount > 0 ? "Mark all watched" : "Mark all unwatched",
                            systemImage: "checkmark")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    DownloadButton(target: .channel(channel))
                }
                kidsRules(channel)
                if let overview = channel.overview {
                    Text(overview).font(.system(size: 13)).foregroundStyle(Theme.synopsis)
                        .frame(maxWidth: 560, alignment: .leading)
                }
            }
        }
    }
}
