import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// Movie, Show, Season or Episode details, by the item's kind. Menu goes back.
struct DetailView: View {
    @Environment(CatalogModel.self) private var model
    let id: Item.ID
    let capabilities: SystemCapabilities

    var body: some View {
        Group {
            if let item = model.catalog.item(id) {
                switch item.kind {
                case .movie, .episode: PlayableDetail(item: item, capabilities: capabilities)
                case .show: ShowDetail(item: item)
                case .season: SeasonDetail(item: item)
                }
            } else {
                Text("Not available").font(.system(size: 34)).foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.ground)
        .ignoresSafeArea()
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// `2h 46m  2024  R  [4K] [HDR]  23m left`, spaced as the boards space it.
struct MetaLine: View {
    let parts: [String]
    var tags: [String] = []
    var left: String?

    var body: some View {
        HStack(spacing: 22) {
            ForEach(parts.filter { !$0.isEmpty }, id: \.self) { Text($0) }
            ForEach(tags, id: \.self) { Tag(text: $0) }
            if let left { Text(left).foregroundStyle(Theme.amber) }
        }
        .font(.system(size: 30))
        .foregroundStyle(Theme.secondary)
    }
}

/// A key in the dim left column, its value beside it.
struct KeyValue<Value: View>: View {
    let key: String
    var keyWidth: CGFloat = 134
    @ViewBuilder var value: Value

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(key).foregroundStyle(Theme.secondary).frame(width: keyWidth, alignment: .leading)
            value.foregroundStyle(Theme.light)
        }
        .font(.system(size: 28))
        .accessibilityElement(children: .combine)
    }
}

extension KeyValue where Value == Text {
    init(key: String, keyWidth: CGFloat = 134, value: String) {
        self.init(key: key, keyWidth: keyWidth) { Text(value) }
    }
}

/// A movie or an episode: the things that play.
struct PlayableDetail: View {
    @Environment(CatalogModel.self) private var model
    @Environment(Browser.self) private var browser
    @Environment(AppModel.self) private var app
    let item: Item
    @State private var audioTrackId: UID?
    @State private var cuts = EditionChoice()
    @State private var verdict: Components.Schemas.Verdict?
    @State private var credits: Credits?
    @State private var related: ItemRelated?
    // The player's source of facts, so details and play send the same groups.
    let capabilities: SystemCapabilities
    @State private var together: WatchTogetherModel?
    @Environment(CollectionsModel.self) private var collections
    @State private var collectionsIn: [MovieCollection] = []

    var body: some View {
        let catalog = model.catalog
        let episode = item.kind == .episode
        let resumes = cuts.resumes(catalog.watch[item.id])
        let meta = MetaLine(
            parts: [
                item.metadata?.runtimeMinutes.map { Format.runtime(minutes: $0) } ?? "",
                episode ? DateText.release(item) : Catalog.year(item).map(String.init) ?? "",
                episode ? "" : item.metadata?.contentRating ?? "",
            ], tags: media?.tags ?? [],
            left: resumes ? catalog.remainingMs(item.id).map(Format.remaining) : nil)
        let progress = resumes ? catalog.progress(item.id) : nil
        ScrollView {
            VStack(alignment: .leading, spacing: 50) {
                HStack(alignment: .top, spacing: 56) {
                    ArtBlock(item: item, aspect: episode ? 16 / 9 : 2 / 3, radius: 16).frame(width: episode ? 560 : 400)
                        .overlay(alignment: .bottom) { if let progress { ProgressBar(value: progress) } }
                    VStack(alignment: .leading, spacing: 0) {
                        if episode, let show = catalog.show(of: item), let season = catalog.parent(of: item) {
                            Text("\(Catalog.title(show)) · \(Catalog.title(season))").font(
                                .system(size: 30, weight: .semibold)
                            )
                            .foregroundStyle(Theme.secondary)
                        }
                        Text(episode ? "\(item.episodeNumber ?? 0). \(Catalog.title(item))" : Catalog.title(item))
                            .font(.system(size: 80, weight: .bold)).lineLimit(2).minimumScaleFactor(0.6)
                        meta.padding(.top, 12)
                        HStack(spacing: 24) { actions(catalog) }.padding(.top, 32).focusSection()
                        NeighborButtons(related: related)
                        if let together { TogetherNote(together: together, title: Catalog.title(item)) }
                        if let overview = item.metadata?.overview {
                            Text(overview).font(.system(size: 28)).foregroundStyle(Theme.synopsis).lineLimit(4)
                                .padding(.top, 30)
                        }
                        details.padding(.top, 30)
                        if !collectionsIn.isEmpty { CollectionsLine(collections: collectionsIn).padding(.top, 30) }
                    }
                }
                if !episode, let related { RelatedShelves(related: related) }
                if !episode { OccasionShelves(itemId: item.id) }
                if let credits, !episode, !credits.cast.isEmpty { CastRow(credits: credits) }
                if episode { UpNext(after: item) }
            }
            .padding(Theme.safeArea)
        }
        .scrollClipDisabled()
        .onChange(of: cuts.file?.id) { audioTrackId = media?.defaultAudio?.id }
        .task(id: item.id) {
            await cuts.load(item.id, from: model)
            credits = await model.credits(item.id)
            if !episode { collectionsIn = await collections.collections(of: item.id) }
        }
        .task(id: item.id) { related = await model.related(item.id) }
        // Another title in this same page shows nothing of the last one's while its own loads.
        .onChange(of: item.id) { related = nil }
        .task(id: item.id) {
            guard let session = app.watchTogether(itemId: item.id) else { return }
            let catalog = model
            session.onStart = { [weak session] ms in
                if let session { browser.play(item, in: catalog.catalog, from: ms, together: session) }
            }
            together = session
            await session.run()
        }
        .task(id: "\(item.id) \(capabilities.path)") {
            if let endpoint = app.endpoint {
                verdict = await model.playability(item.id, facts: capabilities.facts(), server: endpoint)?.verdict
            }
        }
    }

    @ViewBuilder
    private func actions(_ catalog: Catalog) -> some View {
        let inProgress = cuts.resumes(catalog.watch[item.id])
        let watched = catalog.isWatched(item.id)
        let synced = together?.inSync == true
        // Opening or inside Watch together, which plays the default edition.
        let sharing = together?.current != nil
        Button {
            // Plays for both; each side's player opens as the shared state turns to playing.
            if synced, let together {
                Task { await together.playTogether() }
            } else {
                browser.play(
                    item, in: catalog, audioTrackId: audioTrackId, edition: cuts.sent(together: sharing),
                    together: together)
            }
        } label: {
            Label(synced ? "Play together" : inProgress ? "Resume" : "Play", systemImage: "play.fill")
        }
        .buttonStyle(TVButtonStyle(primary: true))
        if inProgress && !synced {
            Button("Start over") {
                browser.play(
                    item, in: catalog, audioTrackId: audioTrackId, edition: cuts.sent(together: sharing), from: 0)
            }
            .buttonStyle(TVButtonStyle())
        }
        if !sharing { EditionMenu(cuts: cuts) }
        Button {
            Task { await model.setWatched(!watched, for: item) }
        } label: {
            Label(watched ? "Mark unwatched" : "Mark watched", systemImage: "checkmark")
        }
        .buttonStyle(TVButtonStyle())
        if let together { TogetherButtons(together: together) }
    }

    /// The tracks of the chosen edition's first copy.
    private var media: MediaSummary? { cuts.file.map(MediaSummary.init) }

    @ViewBuilder
    private var details: some View {
        let crew = credits.map(CrewLines.init)?.lines(episode: item.kind == .episode) ?? []
        let width: CGFloat = item.kind == .episode ? 164 : 134
        VStack(alignment: .leading, spacing: 14) {
            ForEach(crew, id: \.0) { job, names in KeyValue(key: job, keyWidth: width, value: names) }
            if item.kind == .movie, let genres = item.genres, !genres.isEmpty {
                KeyValue(key: "Genres", keyWidth: width, value: genres.map(\.name).joined(separator: ", "))
            }
            if let media {
                if media.audio.count > 1 {
                    KeyValue(key: "Audio", keyWidth: width) {
                        Menu {
                            Picker("Audio track", selection: $audioTrackId) {
                                ForEach(media.audio) { Text(media.label($0)).tag(Optional($0.id)) }
                            }
                        } label: {
                            HStack(spacing: 16) {
                                Text(media.audio.first { $0.id == audioTrackId }.map(media.label) ?? "")
                                Image(systemName: "chevron.down").font(.system(size: 20, weight: .bold))
                            }
                        }
                        .buttonStyle(ChipStyle(selected: false, radius: 12))
                    }
                } else if let audio = media.defaultAudio {
                    KeyValue(key: "Audio", keyWidth: width, value: media.label(audio))
                }
                if !media.subtitles.isEmpty { KeyValue(key: "Subtitles", keyWidth: width, value: media.subtitleLine) }
                if let video = media.videoLine {
                    KeyValue(key: "Video", keyWidth: width) {
                        if let verdict {
                            let label = Text(Format.verdict(verdict)).bold()
                                .foregroundColor(verdict == .directPlay ? Theme.green : Theme.amber)
                            Text("\(video) · \(label) on this device")
                        } else {
                            Text(video)
                        }
                    }
                }
            }
        }
    }
}

/// A show: its seasons, a Resume for the right episode, and the cast.
struct ShowDetail: View {
    @Environment(CatalogModel.self) private var model
    @Environment(Browser.self) private var browser
    let item: Item
    @State private var credits: Credits?

    var body: some View {
        let catalog = model.catalog
        let target = catalog.resumeTarget(for: item.id)
        let unwatched = catalog.unwatchedCount(item.id)
        let left = target.flatMap { target in
            catalog.remainingMs(target.id).map { "\(Format.remaining(ms: $0)) in \(Format.episodeCode(target))" }
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 50) {
                HStack(alignment: .top, spacing: 56) {
                    ArtBlock(item: item, radius: 16).frame(width: 400)
                        .overlay(alignment: .bottom) {
                            if let progress = catalog.resumeProgress(item.id) { ProgressBar(value: progress) }
                        }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(Catalog.title(item)).font(.system(size: 80, weight: .bold)).lineLimit(2)
                            .minimumScaleFactor(0.6)
                        MetaLine(
                            parts: catalog.caption(item).components(separatedBy: " · ") + [
                                Catalog.year(item).map { "\($0)–" } ?? "", item.metadata?.contentRating ?? "",
                            ], left: left
                        )
                        .padding(.top, 12)
                        HStack(spacing: 24) {
                            if let target {
                                Button {
                                    browser.play(target, in: catalog)
                                } label: {
                                    Label(ResumeText.title(target, in: item, catalog), systemImage: "play.fill")
                                }
                                .buttonStyle(TVButtonStyle(primary: true))
                            }
                            MarkAllButton(item: item, unwatched: unwatched)
                        }
                        .padding(.top, 32)
                        .focusSection()
                        if let overview = item.metadata?.overview {
                            Text(overview).font(.system(size: 28)).foregroundStyle(Theme.synopsis).lineLimit(3)
                                .padding(.top, 30)
                        }
                        Text("Seasons").font(.system(size: 34, weight: .bold)).padding(.top, 36)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 28) {
                                ForEach(catalog.children(of: item.id)) { SeasonTile(item: $0) }
                            }
                            .padding(.vertical, 20)
                        }
                        .scrollClipDisabled()
                        .focusSection()
                    }
                }
                if let credits, !credits.cast.isEmpty { CastRow(credits: credits) }
            }
            .padding(Theme.safeArea)
        }
        .scrollClipDisabled()
        .task(id: item.id) { credits = await model.credits(item.id) }
    }
}

/// A season: the poster and actions on the left, its episodes down the right.
struct SeasonDetail: View {
    @Environment(CatalogModel.self) private var model
    @Environment(Browser.self) private var browser
    let item: Item
    @FocusState private var episode: Item.ID?

    var body: some View {
        let catalog = model.catalog
        let target = catalog.resumeTarget(for: item.id)
        let unwatched = catalog.unwatchedCount(item.id)
        let children = catalog.children(of: item.id)
        let show = catalog.parent(of: item)
        HStack(alignment: .top, spacing: 56) {
            VStack(alignment: .leading, spacing: 0) {
                ArtBlock(item: item, radius: 16).frame(width: 280)
                    .overlay(alignment: .bottom) {
                        if let progress = catalog.resumeProgress(item.id) { ProgressBar(value: progress) }
                    }
                Text([show.map(Catalog.title), Catalog.title(item)].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 48, weight: .bold)).lineLimit(2).minimumScaleFactor(0.6).padding(.top, 26)
                MetaLine(parts: [
                    "\(children.count) episodes", "\(unwatched) unwatched", Catalog.year(item).map(String.init) ?? "",
                ])
                .padding(.top, 8)
                HStack(spacing: 20) {
                    if let target {
                        Button {
                            browser.play(target, in: catalog)
                        } label: {
                            Label(ResumeText.title(target, in: item, catalog), systemImage: "play.fill")
                        }
                        .buttonStyle(TVButtonStyle(primary: true))
                    }
                    MarkAllButton(item: item, unwatched: unwatched)
                }
                .padding(.top, 30)
                .focusSection()
                if let overview = item.metadata?.overview {
                    Text(overview).font(.system(size: 28)).foregroundStyle(Theme.synopsis).lineLimit(5)
                        .padding(.top, 30)
                }
            }
            .frame(width: 560, alignment: .leading)
            .padding(.top, 20)
            ScrollView {
                VStack(spacing: 28) {
                    ForEach(children) { EpisodeRow(item: $0).focused($episode, equals: $0.id) }
                }
                .padding(.vertical, 34)
                .padding(.horizontal, 20)
            }
            .scrollClipDisabled()
            .focusSection()
            .defaultFocus($episode, target?.id)
        }
        .padding(Theme.safeArea)
    }
}

/// `Resume S2 E4` on a show, `Resume E4` on a season; Play before it starts.
enum ResumeText {
    @MainActor
    static func title(_ target: Item, in item: Item, _ catalog: Catalog) -> String {
        let code = item.kind == .show ? Format.episodeCode(target) : "E\(target.episodeNumber ?? 0)"
        return catalog.isInProgress(target.id) ? "Resume \(code)" : "Play \(code)"
    }
}

struct MarkAllButton: View {
    @Environment(CatalogModel.self) private var model
    let item: Item
    let unwatched: Int

    var body: some View {
        Button {
            Task { await model.setWatched(unwatched > 0, for: item) }
        } label: {
            Label(unwatched == 0 ? "Mark all unwatched" : "Mark all watched", systemImage: "checkmark")
        }
        .buttonStyle(TVButtonStyle())
    }
}
