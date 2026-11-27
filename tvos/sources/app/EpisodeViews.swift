import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

struct SeasonTile: View {
    @Environment(CatalogModel.self) private var model
    @Environment(Browser.self) private var browser
    let item: Item

    var body: some View {
        let unwatched = model.catalog.unwatchedCount(item.id)
        Button {
            browser.open(item)
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                ArtBlock(item: item, aspect: 144 / 180).frame(width: 144)
                    .overlay(alignment: .topTrailing) {
                        if unwatched > 0 { NewBadge(count: unwatched).scaleEffect(0.8) }
                    }
                    .overlay(alignment: .bottom) {
                        if let progress = model.catalog.resumeProgress(item.id) {
                            ProgressBar(value: progress).padding(14)
                        }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(Catalog.title(item)).font(.system(size: 28, weight: .semibold)).lineLimit(1)
                    Text("\(model.catalog.children(of: item.id).count) episodes").font(.system(size: 26))
                        .foregroundStyle(.secondary)
                }
                .fixedSize()
            }
        }
        .buttonStyle(CardButtonStyle())
        .contextMenu { ItemContextMenu(item: item) }
    }
}

struct EpisodeRow: View {
    @Environment(CatalogModel.self) private var model
    @Environment(Browser.self) private var browser
    let item: Item

    var body: some View {
        let catalog = model.catalog
        Button {
            browser.open(item)
        } label: {
            HStack(alignment: .center, spacing: 28) {
                ArtBlock(item: item, aspect: 16 / 9, radius: 12).frame(width: 240)
                    .overlay(alignment: .bottom) {
                        if let progress = catalog.progress(item.id) { ProgressBar(value: progress, height: 6) }
                    }
                    .overlay(alignment: .topTrailing) {
                        if catalog.isWatched(item.id) {
                            Image(systemName: "checkmark").font(.system(size: 18, weight: .heavy))
                                .foregroundStyle(Theme.green).frame(width: 36, height: 36)
                                .background(.black.opacity(0.6), in: .circle).padding(10)
                                .accessibilityLabel("Watched")
                        }
                    }
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(item.episodeNumber ?? 0). \(Catalog.title(item))").font(.system(size: 32, weight: .bold))
                        .lineLimit(1)
                    HStack(spacing: 0) {
                        Text(
                            [item.metadata?.runtimeMinutes.map { Format.runtime(minutes: $0) }, DateText.release(item)]
                                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                        )
                        .foregroundStyle(.secondary)
                        if let left = catalog.remainingMs(item.id) {
                            Text(" · ").foregroundStyle(.secondary)
                            Text(Format.remaining(ms: left)).bold().foregroundStyle(Theme.amber)
                        }
                    }
                    .font(.system(size: 26))
                    if let overview = item.metadata?.overview {
                        Text(overview).font(.system(size: 26)).lineLimit(1).opacity(0.9)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(RowButtonStyle())
        .contextMenu { ItemContextMenu(item: item) }
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
            VStack(alignment: .leading, spacing: 24) {
                Text("Up next").font(.system(size: 34, weight: .bold))
                HStack(alignment: .top, spacing: 28) {
                    ForEach(next) { EpisodeRow(item: $0).background(Theme.card, in: .rect(cornerRadius: 20)) }
                }
            }
            .focusSection()
        }
    }
}

/// `Feb 7, 2025` from an episode's air date.
enum DateText {
    static func release(_ item: Item) -> String { day(item.metadata?.releaseDate) }

    static func day(_ text: String?) -> String {
        guard let text,
            let date = try? Date(String(text.prefix(10)), strategy: .iso8601.year().month().day())
        else { return "" }
        // The air date is a calendar day, parsed as midnight UTC; read it back in UTC so no zone shifts the day.
        return date.formatted(
            Date.FormatStyle(date: .abbreviated, time: .omitted, locale: Locale(identifier: "en_US"), timeZone: .gmt))
    }
}
