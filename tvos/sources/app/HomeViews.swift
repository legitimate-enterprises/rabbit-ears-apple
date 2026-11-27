import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

struct HomeView: View {
    @Environment(CatalogModel.self) private var model
    @Environment(AppModel.self) private var app
    @Environment(Browser.self) private var browser
    @State private var startedVideos: [YouTubeVideo] = []
    @State private var channelVideos: [YouTubeVideo] = []
    @State private var occasions = OccasionsModel()

    var body: some View {
        let catalog = model.catalog
        let hero = HomeHero(catalog.continueWatching(with: startedVideos))
        ScrollView {
            VStack(alignment: .leading, spacing: 56) {
                if catalog.items.isEmpty {
                    Text("Nothing here yet.").font(.system(size: 34)).foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity).padding(.top, 200)
                }
                if let hero {
                    HeroTile(entry: hero.hero)
                    VideoShelf(title: "Also in progress", entries: hero.alsoInProgress)
                }
                Shelf(title: "Next up", items: catalog.nextUp, wide: true, plays: true)
                OnNowShelf()
                ForEach(occasions.shelves) { shelf in
                    Shelf(
                        title: shelf.title, items: shelf.items, wide: false,
                        seeAll: (shelf.name, { browser.open(.occasion(shelf.occasion)) }))
                }
                ForEach(app.homeSlots(model.profileId).occasions(answered: occasions.answered)) {
                    RowPlaceholder(slot: $0)
                }
                Shelf(title: "Recently added", items: catalog.recentlyAdded, wide: false)
                VideoShelf(title: "New from your channels", entries: channelVideos.map(Resumable.video))
            }
            .padding(.top, shellTop - 20)
            .padding(.bottom, 60)
        }
        .scrollClipDisabled()
        .reloadingOccasions(occasions, with: model)
        .background(alignment: .top) {
            if let hero {
                HeroTile.art(hero.hero, catalog)
                    .frame(height: 760)
                    .overlay(
                        LinearGradient(
                            colors: [.black.opacity(0.55), .black.opacity(0.1)], startPoint: .leading,
                            endPoint: .trailing)
                    )
                    .overlay(LinearGradient(colors: [.clear, Theme.ground], startPoint: .center, endPoint: .bottom))
                    .opacity(0.8)
                    .accessibilityHidden(true)
            }
        }
        // Again when a player closes, so a video just finished leaves.
        .task(id: browser.returns) {
            startedVideos = (try? await app.youTubeModel?.inProgress()) ?? startedVideos
            channelVideos = (try? await app.youTubeModel?.newFromChannels()) ?? channelVideos
        }
    }
}

struct HeroTile: View {
    @Environment(CatalogModel.self) private var model
    @Environment(Browser.self) private var browser
    let entry: Resumable

    var body: some View {
        let catalog = model.catalog
        VStack(alignment: .leading, spacing: 0) {
            Text("Continue watching").font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Theme.amber)
            Text(entry.title(catalog)).font(.system(size: 88, weight: .bold)).lineLimit(1).padding(.top, 8)
            Text(entry.line(catalog)).font(.system(size: 34)).foregroundStyle(Theme.synopsis)
            if let progress = entry.progress(catalog) {
                ProgressBar(value: progress).frame(width: 520).padding(.top, 26)
            }
            HStack(spacing: 24) {
                Button {
                    switch entry {
                    case .item(let item): browser.play(item, in: catalog)
                    case .video(let video): browser.play(video)
                    }
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .buttonStyle(TVButtonStyle(primary: true))
                .contextMenu {
                    switch entry {
                    case .item(let item): ItemContextMenu(item: item)
                    case .video(let video): VideoContextMenu(video: video)
                    }
                }
                Button("Details") {
                    switch entry {
                    case .item(let item): browser.open(catalog.show(of: item) ?? item)
                    case .video(let video): browser.open(.video(video.id))
                    }
                }
                .buttonStyle(TVButtonStyle())
            }
            .padding(.top, 34)
        }
        .padding(.horizontal, 80)
        .focusSection()
    }

    static func art(_ entry: Resumable, _ catalog: Catalog) -> ArtImage {
        switch entry {
        case .item(let item): ArtImage(item: catalog.show(of: item) ?? item, kind: .backdrop)
        case .video(let video): ArtImage(id: video.id, kind: .poster, placeholder: .video)
        }
    }
}

extension EpisodeText {
    /// The caption under a wide tile: `S4 E1 · 49m`.
    @MainActor
    static func short(_ item: Item, _ catalog: Catalog) -> String {
        guard item.kind == .episode else { return catalog.caption(item) }
        let runtime = item.metadata?.runtimeMinutes.map { Format.runtime(minutes: $0) }
        return ([Format.episodeCode(item)] + [runtime].compactMap { $0 }).joined(separator: " · ")
    }
}

/// A row's space, as the last Home showed it, until its own answer comes: flat tiles the size of its real ones.
struct RowPlaceholder: View {
    let slot: HomeSlot

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(slot.title).font(.system(size: 34, weight: .bold)).padding(.horizontal, 80)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 40) {
                    ForEach(Array(slot.wide.enumerated()), id: \.offset) { index, wide in
                        VStack(alignment: .leading, spacing: 14) {
                            Color(hex: ArtPalette.colors[index % ArtPalette.colors.count])
                                .aspectRatio(wide ? 16 / 9 : slot.row == .onNow ? 1 : 2 / 3, contentMode: .fit)
                                .clipShape(.rect(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Title").font(.system(size: 28, weight: .semibold))
                                Text("Caption").font(.system(size: 26))
                            }
                            .redacted(reason: .placeholder)
                        }
                        .frame(width: wide ? 380 : 220)
                    }
                }
                .padding(.vertical, 20)
            }
            .contentMargins(.horizontal, 80, for: .scrollContent)
            .scrollClipDisabled()
            .scrollDisabled(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(slot.title), loading")
    }
}

struct Shelf: View {
    let title: String
    let items: [Item]
    let wide: Bool
    /// The name of what the shelf shows part of, and the way to its whole list: a last tile.
    var seeAll: (name: String, open: () -> Void)?
    /// A tile plays its title instead of opening it.
    var plays = false

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 24) {
                Text(title).font(.system(size: 34, weight: .bold)).padding(.horizontal, 80)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 40) {
                        ForEach(items) { Tile(item: $0, wide: wide, plays: plays).frame(width: wide ? 380 : 220) }
                        if let seeAll {
                            Button(action: seeAll.open) {
                                Text("See all").font(.system(size: 28, weight: .semibold))
                                    .frame(width: wide ? 380 : 220, height: wide ? 214 : 330)
                            }
                            .buttonStyle(CardButtonStyle())
                            .accessibilityLabel("See all \(seeAll.name)")
                        }
                    }
                    .padding(.vertical, 20)
                }
                .contentMargins(.horizontal, 80, for: .scrollContent)
                .scrollClipDisabled()
            }
            .focusSection()
        }
    }
}

/// Wide tiles of titles and videos together.
struct VideoShelf: View {
    let title: String
    let entries: [Resumable]

    var body: some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 24) {
                Text(title).font(.system(size: 34, weight: .bold)).padding(.horizontal, 80)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 40) {
                        ForEach(entries) { entry in
                            switch entry {
                            case .item(let item): Tile(item: item, wide: true).frame(width: 380)
                            case .video(let video): VideoTile(video: video).frame(width: 380)
                            }
                        }
                    }
                    .padding(.vertical, 20)
                }
                .contentMargins(.horizontal, 80, for: .scrollContent)
                .scrollClipDisabled()
            }
            .focusSection()
        }
    }
}

struct Tile: View {
    @Environment(CatalogModel.self) private var model
    @Environment(Browser.self) private var browser
    let item: Item
    var wide = false
    /// Plays at once, with a play arrow over the art; the long-press menu goes to the details.
    var plays = false

    var body: some View {
        let catalog = model.catalog
        let show = item.kind == .episode ? catalog.show(of: item) : nil
        // A show's count walks every episode under it; once per render.
        let unwatched = catalog.unwatchedCount(item.id)
        Button {
            if plays { browser.play(item, in: catalog) } else { browser.open(item) }
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                ArtBlock(item: item, aspect: wide ? 16 / 9 : 2 / 3)
                    .overlay(alignment: .topTrailing) { marker(unwatched) }
                    .overlay { if plays { PlayBadge(size: 72) } }
                    .overlay(alignment: .bottom) {
                        if let progress = catalog.resumeProgress(item.id) { ProgressBar(value: progress).padding(14) }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(Catalog.title(show ?? item)).font(.system(size: 28, weight: .semibold)).lineLimit(1)
                    Text(EpisodeText.short(item, catalog)).font(.system(size: 26)).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(CardButtonStyle())
        .labeled(plays ? EpisodeText.playLabel(item, catalog) : nil)
        .contextMenu { ItemContextMenu(item: item, details: plays ? { browser.open(item) } : nil) }
    }

    @ViewBuilder
    private func marker(_ unwatched: Int) -> some View {
        if item.kind == .show, unwatched > 0 {
            NewBadge(count: unwatched)
        } else if item.kind == .movie, unwatched > 0 {
            Circle().fill(Theme.amber).frame(width: 22, height: 22)
                .overlay(Circle().stroke(.black.opacity(0.35), lineWidth: 3)).padding(14)
                .accessibilityLabel("Unwatched")
        }
    }
}
