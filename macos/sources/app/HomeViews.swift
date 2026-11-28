import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(CatalogModel.self) private var model
    @Environment(Browser.self) private var browser
    @State private var videos: [YouTubeVideo] = []
    @State private var started: [YouTubeVideo] = []
    @State private var occasions = OccasionsModel()

    var body: some View {
        let catalog = model.catalog
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if catalog.items.isEmpty {
                    Text("Nothing here yet.").foregroundStyle(Theme.secondary).frame(maxWidth: .infinity).padding(60)
                }
                if let hero = HomeHero(catalog.continueWatching(with: started)) {
                    HStack(alignment: .top, spacing: 18) {
                        HeroTile(entry: hero.hero, wide: hero.alsoInProgress.isEmpty)
                        if !hero.alsoInProgress.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Also in progress").font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Theme.secondary)
                                ForEach(hero.alsoInProgress.prefix(3)) { entry in
                                    switch entry {
                                    case .item(let item): InProgressRow(item: item)
                                    case .video(let video): InProgressVideoRow(video: video)
                                    }
                                }
                            }
                            .frame(maxWidth: 320)
                        }
                    }
                }
                Strip(title: "Next up", items: catalog.nextUp, wide: true, plays: true)
                OnNowStrip()
                ForEach(occasions.shelves) { shelf in
                    Strip(
                        title: shelf.title, items: shelf.items, wide: false,
                        seeAll: (shelf.name, { browser.open(.occasion(shelf.occasion)) }))
                }
                ForEach(app.homeSlots(model.profileId).occasions(answered: occasions.answered)) {
                    RowPlaceholder(slot: $0)
                }
                Strip(title: "Recently added", items: catalog.recentlyAdded, wide: false)
                VideoStrip(title: "New from your channels", videos: videos)
            }
            .padding(EdgeInsets(top: 34, leading: 22, bottom: 24, trailing: 22))
        }
        .reloadingOccasions(occasions, with: model)
        .task(id: browser.revision) {
            guard let youtube = app.youtubeModel else { return }
            async let new = youtube.newFromChannels()
            async let inProgress = youtube.inProgress()
            videos = (try? await new) ?? []
            started = (try? await inProgress) ?? []
        }
    }
}

struct HeroTile: View {
    @Environment(CatalogModel.self) private var model
    @Environment(Browser.self) private var browser
    let entry: Resumable
    let wide: Bool

    var body: some View {
        let catalog = model.catalog
        VStack(alignment: .leading, spacing: 6) {
            Spacer()
            Text("Continue watching").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.amber)
            Text(entry.title(catalog)).font(.system(size: 26, weight: .bold))
            Text(entry.line(catalog)).font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(hex: 0xD5D8E6))
            if let progress = entry.progress(catalog) {
                ProgressBar(value: progress).frame(width: 240).padding(.top, 4)
            }
            HStack(spacing: 10) {
                Button {
                    switch entry {
                    case .item(let item): browser.play(item, in: catalog)
                    case .video(let video): browser.play(video)
                    }
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle(height: 30))
                .needsServer(.play, entry.itemId)
                Button("Details") {
                    switch entry {
                    case .item(let item): browser.open(catalog.show(of: item) ?? item)
                    case .video(let video): browser.open(.video(video.id))
                    }
                }
                .buttonStyle(SecondaryButtonStyle(height: 30))
            }
            .padding(.top, 8)
        }
        .padding(20)
        .frame(width: wide ? nil : 560, height: 250, alignment: .leading)
        .frame(maxWidth: wide ? .infinity : nil, alignment: .leading)
        .background {
            art(catalog)
                .overlay(
                    LinearGradient(
                        colors: [.black.opacity(0.85), .black.opacity(0.2)], startPoint: .leading, endPoint: .trailing)
                )
                .clipShape(.rect(cornerRadius: 10))
        }
        .contextMenu {
            switch entry {
            case .item(let item):
                ItemContextMenu(
                    item: item, play: { browser.play(item, in: catalog) },
                    goToShow: (item.kind == .episode ? catalog.show(of: item) : nil).map { show in
                        { browser.open(show) }
                    })
            case .video(let video): VideoContextMenu(video: video)
            }
        }
    }

    private func art(_ catalog: Catalog) -> ArtImage {
        switch entry {
        case .item(let item): ArtImage(item: catalog.show(of: item) ?? item, kind: .backdrop)
        case .video(let video): ArtImage(id: video.id, placeholder: .video)
        }
    }
}

struct InProgressRow: View {
    @Environment(CatalogModel.self) private var model
    @Environment(Browser.self) private var browser
    let item: Item

    var body: some View {
        let catalog = model.catalog
        Button {
            browser.play(item, in: catalog)
        } label: {
            HStack(spacing: 10) {
                ArtBlock(item: item, aspect: 16 / 9).frame(width: 88)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Catalog.title(catalog.show(of: item) ?? item)).font(.system(size: 12, weight: .semibold))
                    Text(EpisodeText.line(item, catalog)).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    if let progress = catalog.progress(item.id) { ProgressBar(value: progress).padding(.top, 4) }
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            ItemContextMenu(
                item: item, play: { browser.play(item, in: catalog) },
                goToShow: (item.kind == .episode ? catalog.show(of: item) : nil).map { show in
                    { browser.open(show) }
                })
        }
    }
}

/// A row's space, as the last Home showed it, until its own answer comes: flat tiles the size of its real ones.
struct RowPlaceholder: View {
    let slot: HomeSlot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(slot.title).font(.system(size: 15, weight: .bold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(Array(slot.wide.enumerated()), id: \.offset) { index, wide in
                        let onNow = slot.row == .onNow
                        VStack(alignment: .leading, spacing: onNow ? 4 : 6) {
                            Color(hex: ArtPalette.colors[index % ArtPalette.colors.count])
                                .aspectRatio(wide ? 16 / 9 : onNow ? 1 : 2 / 3, contentMode: .fit)
                                .clipShape(.rect(cornerRadius: 6))
                                .padding(.bottom, onNow ? 2 : 0)
                            Group {
                                Text("Title").font(.system(size: 12, weight: .semibold))
                                Text("Caption").font(.system(size: 11))
                            }
                            .redacted(reason: .placeholder)
                        }
                        .frame(width: wide ? 224 : onNow ? 126 : 120)
                    }
                }
            }
            .scrollDisabled(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(slot.title), loading")
    }
}

struct Strip: View {
    let title: String
    let items: [Item]
    let wide: Bool
    /// The name of what the row shows part of, and the way to its whole list.
    var seeAll: (name: String, open: () -> Void)?
    /// A tile plays its title instead of opening it.
    var plays = false

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(title).font(.system(size: 15, weight: .bold))
                    Spacer()
                    if let seeAll {
                        Button("See all", action: seeAll.open).buttonStyle(.plain)
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.amber)
                            .accessibilityLabel("See all \(seeAll.name)")
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(items) { Tile(item: $0, wide: wide, plays: plays).frame(width: wide ? 224 : 120) }
                    }
                }
            }
        }
    }
}

struct Tile: View {
    @Environment(CatalogModel.self) private var model
    @Environment(Browser.self) private var browser
    let item: Item
    var wide = false
    /// Plays at once, with a play arrow over the art; the context menu goes to the details.
    var plays = false
    /// Offered as Remove from collection, on a custom collection's page.
    var remove: (() -> Void)?

    var body: some View {
        let catalog = model.catalog
        let show = item.kind == .episode ? catalog.show(of: item) : nil
        Button {
            if plays { browser.play(item, in: catalog) } else { browser.open(item) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                let progress = catalog.resumeProgress(item.id)
                ArtBlock(
                    item: item, aspect: wide ? 16 / 9 : 2 / 3,
                    badges: StatusBadges(id: item.id, overBar: progress != nil)
                )
                .overlay(alignment: .topTrailing) { marker(catalog) }
                .overlay { if plays { PlayBadge() } }
                .overlay(alignment: .bottom) {
                    if let progress { ProgressBar(value: progress).padding(6) }
                }
                Text(Catalog.title(show ?? item)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(item.kind == .episode ? EpisodeText.line(item, catalog) : catalog.caption(item))
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .dimmedOffline(item.id)
        .labeled(plays ? EpisodeText.playLabel(item, catalog) : nil)
        .contextMenu {
            ItemContextMenu(
                item: item, play: { browser.play(item, in: catalog) },
                goToShow: show.map { show in { browser.open(show) } },
                details: plays ? { browser.open(item) } : nil, remove: remove)
        }
    }

    @ViewBuilder
    private func marker(_ catalog: Catalog) -> some View {
        let unwatched = catalog.unwatchedCount(item.id)
        if item.kind == .show, unwatched > 0 {
            Text("\(unwatched) new").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.ground)
                .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.amber, in: .capsule).padding(6)
        } else if item.kind == .movie, unwatched > 0 {
            Circle().fill(Theme.amber).frame(width: 10, height: 10)
                .overlay(Circle().stroke(.black.opacity(0.35), lineWidth: 2)).padding(8)
                .accessibilityLabel("Unwatched")
        }
    }
}
