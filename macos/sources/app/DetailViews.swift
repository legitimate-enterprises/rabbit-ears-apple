import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

struct DetailView: View {
    @Environment(CatalogModel.self) private var model
    let id: Item.ID
    let capabilities: SystemCapabilities

    var body: some View {
        if let item = model.catalog.item(id) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch item.kind {
                    case .movie, .episode: PlayableDetail(item: item, capabilities: capabilities)
                    case .show, .season: GroupDetail(item: item)
                    }
                }
                .padding(EdgeInsets(top: 18, leading: 22, bottom: 24, trailing: 22))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .pageTitle(title(item))
        } else {
            ContentUnavailableView("Not available", systemImage: "questionmark.square.dashed")
        }
    }

    private func title(_ item: Item) -> String {
        switch item.kind {
        case .season: "\(model.catalog.show(of: item).map(Catalog.title) ?? "") · \(Catalog.title(item))"
        default: Catalog.title(item)
        }
    }
}

struct MetaLine: View {
    let parts: [String]
    var tags: [String] = []
    var left: String?

    var body: some View {
        HStack(spacing: 10) {
            ForEach(parts.filter { !$0.isEmpty }, id: \.self) { Text($0) }
            ForEach(tags, id: \.self) { Tag(text: $0) }
            if let left { Text(left).foregroundStyle(Theme.amber) }
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.secondary)
    }
}

struct KeyValue: View {
    let key: String
    let value: String

    var body: some View {
        GridRow {
            Text(key).foregroundStyle(Theme.secondary).gridColumnAlignment(.leading)
            Text(value).textSelection(.enabled)
        }
        .font(.system(size: 13))
    }
}

/// A movie or an episode: the things that play.
struct PlayableDetail: View {
    @Environment(CatalogModel.self) private var model
    @Environment(Browser.self) private var browser
    @Environment(AppModel.self) private var app
    let item: Item
    @State private var media: MediaSummary?
    @State private var audioTrackId: UID?
    @State private var cuts = EditionChoice()
    @State private var verdict: Components.Schemas.Verdict?
    @State private var credits: Credits?
    @State private var related: ItemRelated?
    // The player's source of facts, so details and play send the same network group.
    let capabilities: SystemCapabilities
    @State private var together: WatchTogetherModel?

    var body: some View {
        let catalog = model.catalog
        let episode = item.kind == .episode
        let inProgress = cuts.resumes(catalog.watch[item.id])
        // Opening or inside Watch together, which plays the default edition.
        let sharing = together?.current != nil
        let sent = cuts.sent(together: sharing)
        HStack(alignment: .top, spacing: 24) {
            ArtBlock(item: item, aspect: episode ? 16 / 9 : 2 / 3, radius: 10).frame(width: episode ? 360 : 170)
                .overlay(alignment: .bottom) {
                    if inProgress, let progress = catalog.progress(item.id) { ProgressBar(value: progress, height: 4) }
                }
            VStack(alignment: .leading, spacing: 14) {
                if episode, let show = catalog.show(of: item), let season = catalog.parent(of: item) {
                    Button("\(Catalog.title(show)) · \(Catalog.title(season))") { browser.open(season) }
                        .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                Text(episode ? "\(item.episodeNumber ?? 0). \(Catalog.title(item))" : Catalog.title(item))
                    .font(.system(size: 26, weight: .bold))
                MetaLine(
                    parts: [
                        item.metadata?.runtimeMinutes.map { Format.runtime(minutes: $0) } ?? "",
                        episode ? item.metadata?.releaseDate ?? "" : Catalog.year(item).map(String.init) ?? "",
                        episode ? "" : item.metadata?.contentRating ?? "",
                    ], tags: media?.tags ?? [],
                    left: inProgress ? catalog.remainingMs(item.id).map { Format.remaining(ms: $0) } : nil)
                if !episode { GenreTags(item: item) }
                if item.kind == .movie { InCollections(movieId: item.id) }
                if let verdict { PlayabilityLine(verdict: verdict) }
                HStack(spacing: 10) {
                    Button {
                        // Plays for both; each side's player opens as the shared state turns to playing.
                        if let together, together.inSync {
                            Task { await together.playTogether() }
                        } else {
                            browser.play(
                                item, in: catalog, audioTrackId: audioTrackId, edition: sent, together: together)
                        }
                    } label: {
                        Label(
                            together?.inSync == true ? "Play together" : inProgress ? "Resume" : "Play",
                            systemImage: "play.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle()).needsServer(.play, item.id)
                    if inProgress && together?.inSync != true {
                        Button("Start over") {
                            browser.play(
                                item, in: catalog, audioTrackId: audioTrackId, edition: sent, from: 0,
                                together: together)
                        }
                        .buttonStyle(SecondaryButtonStyle()).needsServer(.play, item.id)
                    }
                    if cuts.offered && !sharing {
                        Picker("Edition", selection: $cuts.editionId) {
                            ForEach(cuts.editions, id: \.id) { Text(Editions.label($0)).tag(Optional($0.id)) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    TogetherControl(together: together)
                    DetailMoreMenu(item: item, editionId: cuts.sent(together: false) ?? nil)
                }
                NeighborButtons(related: related)
                TogetherHint(together: together, title: Catalog.title(item))
                if let overview = item.metadata?.overview {
                    Text(overview).font(.system(size: 13)).foregroundStyle(Theme.synopsis).frame(
                        maxWidth: 560, alignment: .leading)
                }
            }
        }
        if let media {
            VStack(alignment: .leading, spacing: 10) {
                Text("Details").font(.system(size: 15, weight: .bold))
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                    if !episode, media.audio.count > 1 {
                        GridRow {
                            Text("Audio").foregroundStyle(Theme.secondary)
                            Picker("Audio", selection: $audioTrackId) {
                                ForEach(media.audio) { Text(media.label($0)).tag(Optional($0.id)) }
                            }
                            .labelsHidden().fixedSize()
                        }
                        .font(.system(size: 13))
                    } else if let audio = media.defaultAudio {
                        KeyValue(key: "Audio", value: media.label(audio))
                    }
                    if !media.subtitles.isEmpty { KeyValue(key: "Subtitles", value: media.subtitleLine) }
                    if let video = media.videoLine { KeyValue(key: "Video", value: video) }
                    if !episode { KeyValue(key: "File", value: media.fileLine) }
                }
            }
        }
        if !episode, let related {
            ForEach(related.collections, id: \.collection.id) {
                Strip(title: $0.collection.name, items: $0.items, wide: false)
            }
        }
        if !episode { OccasionStrips(itemId: item.id) }
        if let credits, !episode { CreditsSection(credits: credits) }
        if episode { UpNext(after: item) }
        Spacer(minLength: 0)
            .watchTogether(itemId: item.id, model: $together) { position, session in
                browser.play(item, in: model.catalog, audioTrackId: audioTrackId, from: position, together: session)
            }
            .task(id: item.id) {
                await cuts.load(item.id, from: model)
                describe()
                if !episode { credits = await model.credits(item.id) }
            }
            .task(id: item.id) { related = await model.related(item.id) }
            // Another title in this same page shows nothing of the last one's while its own loads.
            .onChange(of: item.id) { related = nil }
            .onChange(of: cuts.editionId) { describe() }
            .task(id: "\(item.id) \(capabilities.path)") {
                if let endpoint = app.endpoint {
                    verdict = await model.playability(item.id, facts: capabilities.facts(), server: endpoint)?.verdict
                }
            }
    }
}

extension PlayableDetail {
    fileprivate func describe() {
        media = cuts.file.map(MediaSummary.init)
        audioTrackId = media?.defaultAudio?.id
    }
}

struct UpNext: View {
    @Environment(CatalogModel.self) private var model
    let after: Item

    var body: some View {
        let catalog = model.catalog
        let episodes = catalog.show(of: after).map { catalog.episodes(under: $0.id) } ?? []
        let next = episodes.firstIndex { $0.id == after.id }.map { Array(episodes.dropFirst($0 + 1).prefix(2)) } ?? []
        if !next.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Up next").font(.system(size: 15, weight: .bold))
                ForEach(next) { EpisodeRow(item: $0) }
            }
        }
    }
}

/// A show or a season: its children and a Resume for the right episode.
struct GroupDetail: View {
    @Environment(CatalogModel.self) private var model
    @Environment(Browser.self) private var browser
    let item: Item
    @State private var credits: Credits?

    var body: some View {
        let catalog = model.catalog
        let target = catalog.resumeTarget(for: item.id)
        let unwatched = catalog.unwatchedCount(item.id)
        let show = item.kind == .show
        let children = catalog.children(of: item.id)
        HStack(alignment: .top, spacing: 24) {
            ArtBlock(item: item, radius: 10).frame(width: show ? 170 : 160)
                .overlay(alignment: .bottom) {
                    if let progress = catalog.resumeProgress(item.id) { ProgressBar(value: progress, height: 4) }
                }
            VStack(alignment: .leading, spacing: 14) {
                Text(
                    show
                        ? Catalog.title(item)
                        : "\(catalog.show(of: item).map(Catalog.title) ?? "") · \(Catalog.title(item))"
                )
                .font(.system(size: 26, weight: .bold))
                MetaLine(
                    parts: show
                        ? [
                            catalog.caption(item), Catalog.year(item).map { "\($0)–" } ?? "",
                            item.metadata?.contentRating ?? "",
                        ]
                        : ["\(children.count) episodes", "\(unwatched) unwatched"],
                    left: target.flatMap { catalog.remainingMs($0.id) }.map {
                        "\(Format.remaining(ms: $0)) in \(Format.episodeCode(target!))"
                    })
                if show { GenreTags(item: item) }
                HStack(spacing: 10) {
                    if let target {
                        Button {
                            browser.play(target, in: catalog)
                        } label: {
                            Label(resumeTitle(target, catalog), systemImage: "play.fill")
                        }
                        .buttonStyle(PrimaryButtonStyle()).needsServer(.play, target.id)
                    }
                    ShuffleButton(items: catalog.episodes(under: item.id))
                    DetailMoreMenu(item: item)
                }
                if let overview = item.metadata?.overview {
                    Text(overview).font(.system(size: 13)).foregroundStyle(Theme.synopsis).frame(
                        maxWidth: 560, alignment: .leading)
                }
            }
        }
        VStack(alignment: .leading, spacing: 10) {
            Text(show ? "Seasons" : "Episodes").font(.system(size: 15, weight: .bold))
            if show {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) { ForEach(children) { SeasonTile(item: $0) } }
                }
            } else {
                ForEach(children) { EpisodeRow(item: $0, current: $0.id == target?.id) }
            }
        }
        .task(id: item.id) { if show { credits = await model.credits(item.id) } }
        if let credits { CreditsSection(credits: credits) }
    }

    private func resumeTitle(_ target: Item, _ catalog: Catalog) -> String {
        let code = item.kind == .show ? Format.episodeCode(target) : "E\(target.episodeNumber ?? 0)"
        return catalog.isInProgress(target.id) ? "Resume \(code)" : "Play \(code)"
    }
}

/// Shuffle on a show, season or collection; absent when nothing in it has a file.
struct ShuffleButton: View {
    @Environment(AppModel.self) private var app
    @Environment(CatalogModel.self) private var catalog
    @Environment(Browser.self) private var browser
    let items: [Item]

    var body: some View {
        if items.contains(where: VideoQueue.shuffles) {
            Button {
                browser.shuffle(items, downloads: app.downloads, profile: catalog.profileId)
            } label: {
                Label("Shuffle", systemImage: "shuffle")
            }
            .buttonStyle(SecondaryButtonStyle()).fixedSize()
        }
    }
}

struct SeasonTile: View {
    @Environment(CatalogModel.self) private var model
    @Environment(Browser.self) private var browser
    let item: Item

    var body: some View {
        let unwatched = model.catalog.unwatchedCount(item.id)
        let progress = model.catalog.resumeProgress(item.id)
        Button {
            browser.open(item)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                ArtBlock(item: item, badges: StatusBadges(id: item.id, overBar: progress != nil)).frame(width: 120)
                    .overlay(alignment: .bottom) { if let progress { ProgressBar(value: progress).padding(6) } }
                    .overlay(alignment: .topTrailing) {
                        if unwatched > 0 {
                            Text("\(unwatched) new").font(.system(size: 10, weight: .bold)).foregroundStyle(
                                Theme.ground
                            )
                            .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.amber, in: .capsule)
                            .padding(6)
                        }
                    }
                Text(Catalog.title(item)).font(.system(size: 12, weight: .semibold))
                Text("\(model.catalog.children(of: item.id).count) episodes").font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain).dimmedOffline(item.id)
        .contextMenu { ItemContextMenu(item: item, play: { browser.play(item, in: model.catalog) }) }
    }
}

struct EpisodeRow: View {
    @Environment(CatalogModel.self) private var model
    @Environment(Browser.self) private var browser
    let item: Item
    var current = false

    var body: some View {
        let catalog = model.catalog
        Button {
            browser.open(item)
        } label: {
            HStack(alignment: .top, spacing: 14) {
                ArtBlock(item: item, aspect: 16 / 9).frame(width: 160)
                    .overlay(alignment: .bottom) {
                        if let progress = catalog.progress(item.id) { ProgressBar(value: progress) }
                    }
                    .overlay(alignment: .topTrailing) {
                        if catalog.isWatched(item.id) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green).padding(6)
                                .accessibilityLabel("Watched")
                        }
                    }
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(item.episodeNumber ?? 0). \(Catalog.title(item))").font(
                        .system(size: 12, weight: .semibold)
                    )
                    .foregroundStyle(current ? Theme.amber : Theme.primary)
                    MetaLine(
                        parts: [
                            item.metadata?.runtimeMinutes.map { Format.runtime(minutes: $0) } ?? "",
                            item.metadata?.releaseDate ?? "",
                        ],
                        left: catalog.remainingMs(item.id).map { Format.remaining(ms: $0) })
                    if let overview = item.metadata?.overview {
                        Text(overview).font(.system(size: 12)).foregroundStyle(Theme.synopsis).lineLimit(2)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 10)
            .overlay(alignment: .top) { Divider().overlay(Theme.hairline) }
            .contentShape(.rect)
        }
        .buttonStyle(.plain).dimmedOffline(item.id)
        .contextMenu { ItemContextMenu(item: item, play: { browser.play(item, in: catalog) }) }
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}
