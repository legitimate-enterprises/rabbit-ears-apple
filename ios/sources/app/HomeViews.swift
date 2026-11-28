import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

struct HomeView: View {
    @Environment(CatalogModel.self) private var model
    @Environment(Services.self) private var services
    @Environment(Browser.self) private var browser
    @Environment(AppModel.self) private var app
    @State private var channelVideos: [YouTubeVideo] = []
    @State private var startedVideos: [YouTubeVideo] = []
    @State private var onNow: [Station] = []
    @State private var onNowAnswered = false
    @State private var occasions = OccasionsModel()

    var body: some View {
        let catalog = model.catalog
        let slots = app.homeSlots(model.profileId)
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if catalog.items.isEmpty {
                    Text("Nothing here yet.").foregroundStyle(Theme.secondary).frame(maxWidth: .infinity).padding(60)
                }
                if let hero = HomeHero(catalog.continueWatching(with: startedVideos)) {
                    HeroTile(entry: hero.hero)
                    ProgressStrip(entries: hero.alsoInProgress)
                }
                Strip(title: "Next up", items: catalog.nextUp, width: 170, wide: true, plays: true)
                OnNowStrip(list: onNow)
                if onNow.isEmpty, let slot = slots.onNow(answered: onNowAnswered) { RowPlaceholder(slot: slot) }
                ForEach(occasions.shelves) { shelf in
                    Strip(
                        title: shelf.title, items: shelf.items, width: 110, wide: false,
                        seeAll: (shelf.name, { browser.open(.occasion(shelf.occasion)) }))
                }
                ForEach(slots.occasions(answered: occasions.answered)) { RowPlaceholder(slot: $0) }
                Strip(title: "Recently added", items: catalog.recentlyAdded, width: 110, wide: false)
                NewFromChannels(videos: channelVideos)
            }
            .padding(EdgeInsets(top: 4, leading: 20, bottom: 20, trailing: 20))
        }
        // A pull reloads the catalog, which reloads these.
        .reloadingOccasions(occasions, with: model)
        // Again when a player closes, so a video just watched leaves the strip.
        .task(id: "\(browser.playing?.id.uuidString ?? "")/\(browser.revision)") { await loadStrips() }
        .pulling {
            async let catalog: Void = model.load()
            await loadStrips()
            await catalog
        }
    }

    /// A strip the server could not answer keeps what it showed.
    private func loadStrips() async {
        async let new = services.youtube.newFromChannels()
        async let started = services.youtube.inProgress()
        async let stations = services.stations.list()
        channelVideos = (try? await new) ?? channelVideos
        startedVideos = (try? await started) ?? startedVideos
        if let stations = await stations {
            onNow = StationsModel.onNow(stations)
            app.homeShowed(onNow: onNow, profileId: model.profileId)
        }
        onNowAnswered = true
    }
}

/// A row's space, as the last Home showed it, until its own answer comes: flat tiles the size of its real ones.
struct RowPlaceholder: View {
    let slot: HomeSlot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(slot.title).font(.system(size: 20, weight: .bold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Array(slot.wide.enumerated()), id: \.offset) { index, wide in
                        VStack(alignment: .leading, spacing: 5) {
                            Color(hex: ArtPalette.colors[index % ArtPalette.colors.count])
                                .aspectRatio(wide ? 16 / 9 : slot.row == .onNow ? 1 : 2 / 3, contentMode: .fit)
                                .clipShape(.rect(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Title").font(.system(size: 13, weight: .semibold))
                                Text("Caption").font(.system(size: 12))
                            }
                            .redacted(reason: .placeholder)
                        }
                        .frame(width: wide ? 170 : 110)
                    }
                }
            }
            .scrollDisabled(true)
            .contentMargins(.horizontal, 20, for: .scrollContent)
            .padding(.horizontal, -20)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(slot.title), loading")
    }
}

/// Home's Also in progress under the hero: titles and videos, latest played first.
struct ProgressStrip: View {
    let entries: [Resumable]

    var body: some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Also in progress").font(.system(size: 20, weight: .bold))
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(entries) { entry in
                            switch entry {
                            case .item(let item): Tile(item: item, wide: true).frame(width: 170)
                            case .video(let video): VideoTile(video: video).frame(width: 170)
                            }
                        }
                    }
                }
                .contentMargins(.horizontal, 20, for: .scrollContent)
                .padding(.horizontal, -20)
            }
        }
    }
}

/// Home's first slot: what was played last.
struct HeroTile: View {
    @Environment(CatalogModel.self) private var model
    @Environment(Browser.self) private var browser
    let entry: Resumable

    var body: some View {
        let catalog = model.catalog
        VStack(alignment: .leading, spacing: 4) {
            Spacer(minLength: 0)
            Text("Continue watching").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.amber)
            Text(entry.title(catalog)).font(.system(size: 26, weight: .bold)).lineLimit(2)
            Text(entry.line(catalog)).font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(hex: 0xD5D8E6))
            HStack(spacing: 10) {
                Button {
                    switch entry {
                    case .item(let item): browser.play(item, in: catalog)
                    case .video(let video): browser.play(Item(video: video), in: catalog)
                    }
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .needsServer(.play, entry.itemId)
                if let progress = entry.progress(catalog) { ProgressBar(value: progress) }
            }
            .padding(.top, 10)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 210, maxHeight: 210, alignment: .leading)
        .background {
            art(catalog)
                .overlay(LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom))
        }
        .clipShape(.rect(cornerRadius: 14))
        .contentShape(.rect)
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
        .onTapGesture {
            switch entry {
            case .item(let item): browser.open(catalog.show(of: item) ?? item)
            case .video(let video): browser.open(.video(video.id))
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func art(_ catalog: Catalog) -> ArtImage {
        switch entry {
        case .item(let item): ArtImage(item: catalog.show(of: item) ?? item, kind: .backdrop)
        case .video(let video): ArtImage(id: video.id, kind: .poster, placeholder: .video)
        }
    }
}

struct Strip: View {
    let title: String
    let items: [Item]
    let width: CGFloat
    let wide: Bool
    /// The name of what the row shows part of, and the way to its whole list.
    var seeAll: (name: String, open: () -> Void)?
    /// A tile plays its title instead of opening it.
    var plays = false

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(title).font(.system(size: 20, weight: .bold))
                    Spacer()
                    if let seeAll {
                        Button("See all", action: seeAll.open).buttonStyle(.plain)
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.amber)
                            .accessibilityLabel("See all \(seeAll.name)")
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(items) { Tile(item: $0, wide: wide, plays: plays).frame(width: width) }
                    }
                }
                .contentMargins(.horizontal, 20, for: .scrollContent)
                .padding(.horizontal, -20)
            }
        }
    }
}

struct Tile: View {
    @Environment(AppModel.self) private var app
    @Environment(CatalogModel.self) private var model
    @Environment(Browser.self) private var browser
    let item: Item
    var wide = false
    /// Plays at once, with a play arrow over the art; the context menu goes to the details.
    var plays = false
    /// Remove from collection, on a custom collection's screen.
    var remove: (() -> Void)?

    var body: some View {
        let catalog = model.catalog
        let show = item.kind == .episode ? catalog.show(of: item) : nil
        // Offline, a title not on this device opens its details, which read from the replica.
        let plays = self.plays && !app.needsServer(.play, item.id)
        // A show's count walks every episode under it; once per render.
        let unwatched = catalog.unwatchedCount(item.id)
        Button {
            if plays { browser.play(item, in: catalog) } else { browser.open(item) }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                ArtBlock(item: item, aspect: wide ? 16 / 9 : 2 / 3)
                    .overlay(alignment: .topTrailing) { marker(unwatched) }
                    .overlay { if plays { PlayBadge() } }
                VStack(alignment: .leading, spacing: 1) {
                    Text(Catalog.title(show ?? item)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(item.kind == .episode ? EpisodeText.line(item, catalog) : catalog.caption(item))
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                    if let progress = catalog.resumeProgress(item.id) { ProgressBar(value: progress).padding(.top, 5) }
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .dimmedOffline(item.id)
        .labeled(plays ? EpisodeText.playLabel(item, catalog) : nil)
        .contextMenu {
            ItemContextMenu(
                item: item, play: { browser.play(item, in: catalog) }, selectable: true,
                goToShow: show.map { show in { browser.open(show) } },
                details: plays ? { browser.open(item) } : nil, remove: remove)
        }
    }

    @ViewBuilder
    private func marker(_ unwatched: Int) -> some View {
        if item.kind == .show, unwatched > 0 {
            NewBadge(count: unwatched)
        } else if item.kind == .movie, unwatched > 0 {
            Circle().fill(Theme.amber).frame(width: 10, height: 10)
                .overlay(Circle().stroke(.black.opacity(0.35), lineWidth: 2)).padding(8)
                .accessibilityLabel("Unwatched")
        }
    }
}

struct NewBadge: View {
    let count: Int

    var body: some View {
        Text("\(count) new").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.ground)
            .padding(.horizontal, 6).padding(.vertical, 1).background(Theme.amber, in: .capsule).padding(6)
    }
}
