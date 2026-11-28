import RabbitEarsKit
import SwiftUI

struct UpNext: View {
    @Environment(CatalogModel.self) private var model
    let after: Item

    var body: some View {
        let catalog = model.catalog
        let episodes = catalog.show(of: after).map { catalog.episodes(under: $0.id) } ?? []
        let next = episodes.firstIndex { $0.id == after.id }.map { Array(episodes.dropFirst($0 + 1).prefix(2)) } ?? []
        if !next.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Up next").font(.system(size: 17, weight: .bold)).padding(.bottom, 4)
                ForEach(next) { EpisodeRow(item: $0) }
            }
        }
    }
}

struct SeasonTile: View {
    @Environment(CatalogModel.self) private var model
    @Environment(Browser.self) private var browser
    let item: Item

    var body: some View {
        let unwatched = model.catalog.unwatchedCount(item.id)
        Button {
            browser.open(item)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ArtBlock(item: item).frame(width: 110)
                    .overlay(alignment: .topTrailing) { if unwatched > 0 { NewBadge(count: unwatched) } }
                    .overlay(alignment: .bottom) {
                        if let progress = model.catalog.resumeProgress(item.id) { ProgressBar(value: progress) }
                    }
                VStack(alignment: .leading, spacing: 0) {
                    Text(Catalog.title(item)).font(.system(size: 12, weight: .semibold))
                    Text("\(model.catalog.children(of: item.id).count) episodes").font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .dimmedOffline(item.id)
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
            HStack(alignment: .top, spacing: 12) {
                ArtBlock(item: item, aspect: 16 / 9, radius: 6).frame(width: 120)
                    .overlay(alignment: .bottomLeading) {
                        if let progress = catalog.progress(item.id) { ProgressBar(value: progress) }
                    }
                    .overlay(alignment: .topTrailing) {
                        if catalog.isWatched(item.id) {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Theme.green).frame(width: 20, height: 20)
                                .background(.black.opacity(0.6), in: .circle).padding(6)
                                .accessibilityLabel("Watched")
                        }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(item.episodeNumber ?? 0). \(Catalog.title(item))")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(current ? Theme.amber : Theme.primary)
                    MetaLine(
                        parts: [
                            item.metadata?.runtimeMinutes.map { Format.runtime(minutes: $0) } ?? "",
                            item.metadata?.releaseDate ?? "",
                        ],
                        left: catalog.remainingMs(item.id).map { Format.remaining(ms: $0) }
                    )
                    .font(.system(size: 12))
                    if let overview = item.metadata?.overview {
                        Text(overview).font(.system(size: 12)).foregroundStyle(Theme.synopsis).lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 12)
            .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .dimmedOffline(item.id)
        .contextMenu { ItemContextMenu(item: item, play: { browser.play(item, in: catalog) }) }
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}
