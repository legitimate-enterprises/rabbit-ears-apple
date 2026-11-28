import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

struct DetailView: View {
    @Environment(CatalogModel.self) private var model
    let id: Item.ID

    var body: some View {
        Group {
            if let item = model.catalog.item(id) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        switch item.kind {
                        case .movie, .episode: PlayableDetail(item: item)
                        case .show, .season: GroupDetail(item: item)
                        }
                    }
                    .padding(EdgeInsets(top: 4, leading: 16, bottom: 20, trailing: 16))
                }
                .pulling { await model.load() }
            } else {
                ContentUnavailableView("Not available", systemImage: "questionmark.square.dashed")
            }
        }
        .background(Theme.ground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { BrowseToolbar() }
    }
}

struct MetaLine: View {
    let parts: [String]
    var tags: [String] = []
    var left: String?

    /// One line when it fits the phone's width, else the tags and time left wrap below.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                texts
                extras
            }
            VStack(spacing: 6) {
                HStack(spacing: 10) { texts }
                HStack(spacing: 10) { extras }
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.secondary)
    }

    private var texts: some View { ForEach(parts.filter { !$0.isEmpty }, id: \.self) { Text($0) } }

    @ViewBuilder
    private var extras: some View {
        ForEach(tags, id: \.self) { Tag(text: $0) }
        if let left { Text(left).foregroundStyle(Theme.amber) }
    }
}

/// A detail as the iPhone boards stack it: the key small above its value.
struct KeyValue<Value: View>: View {
    let key: String
    @ViewBuilder var value: Value

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            value.font(.system(size: 15)).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

extension KeyValue where Value == Text {
    init(key: String, value: String) {
        self.init(key: key) { Text(value) }
    }
}

/// The centered poster, title and meta line every non-episode page opens with.
struct DetailHeader<Actions: View, Below: View>: View {
    let item: Item
    let title: String
    let posterWidth: CGFloat
    let meta: MetaLine
    var genres = false
    var progress: Double?
    @ViewBuilder var actions: Actions
    /// Whatever goes between the buttons and the synopsis, such as Watch together's state.
    @ViewBuilder var below: Below

    var body: some View {
        VStack(spacing: 14) {
            ArtBlock(item: item, radius: 10).frame(width: posterWidth)
                .overlay(alignment: .bottom) { if let progress { ProgressBar(value: progress, height: 4) } }
            VStack(spacing: 6) {
                Text(title).font(.system(size: 26, weight: .bold)).multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                meta
                if genres { GenreTags(item: item) }
            }
            VStack(spacing: 10) { actions }
            below
            if let overview = item.metadata?.overview {
                Text(overview).font(.system(size: 14)).foregroundStyle(Theme.synopsis)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

extension DetailHeader where Below == EmptyView {
    init(
        item: Item, title: String, posterWidth: CGFloat, meta: MetaLine, genres: Bool = false,
        progress: Double? = nil, @ViewBuilder actions: () -> Actions
    ) {
        self.init(
            item: item, title: title, posterWidth: posterWidth, meta: meta, genres: genres, progress: progress,
            actions: actions, below: { EmptyView() })
    }
}

/// A movie or an episode: the things that play.
struct PlayableDetail: View {
    @Environment(Services.self) private var services
    @Environment(CatalogModel.self) private var model
    @Environment(Browser.self) private var browser
    @Environment(AppModel.self) private var app
    let item: Item
    @State private var audioTrackId: UID?
    @State private var cuts = EditionChoice()
    @State private var verdict: Components.Schemas.Verdict?
    @State private var credits: Credits?
    @State private var related: ItemRelated?
    // The player's source of facts, so details and play send the same network group.
    private let capabilities = AppContext.shared.capabilities
    @State private var together: WatchTogetherModel?
    @State private var addTarget: PlaylistTarget?
    @State private var collections: [MovieCollection] = []
    @State private var collecting = false

    var body: some View {
        let catalog = model.catalog
        let episode = item.kind == .episode
        let meta = MetaLine(
            parts: [
                item.metadata?.runtimeMinutes.map { Format.runtime(minutes: $0) } ?? "",
                episode ? item.metadata?.releaseDate ?? "" : Catalog.year(item).map(String.init) ?? "",
                episode ? "" : item.metadata?.contentRating ?? "",
            ], tags: media?.tags ?? [],
            left: cuts.resumes(catalog.watch[item.id]) ? catalog.remainingMs(item.id).map(Format.remaining) : nil)
        let progress = cuts.resumes(catalog.watch[item.id]) ? catalog.progress(item.id) : nil
        // A stack, not a Group: a Group hands its modifiers, toolbar and tasks included, to every child.
        VStack(alignment: .leading, spacing: 22) {
            if episode {
                episodeHeader(meta, progress, catalog)
            } else {
                DetailHeader(
                    item: item, title: Catalog.title(item), posterWidth: 120, meta: meta, genres: true,
                    progress: progress, actions: { actions(catalog) }, below: { togetherNotice })
            }
            if !episode, let related { RelatedStrips(related: related) }
            if !episode { OccasionStrips(itemId: item.id) }
            if let credits, !episode, !credits.cast.isEmpty { CastRow(credits: credits) }
            details(episode: episode)
            if episode { UpNext(after: item) }
        }
        .navigationTitle(episode ? "" : Catalog.title(item))
        .addToPlaylist($addTarget)
        .sheet(isPresented: $collecting, onDismiss: loadCollections) {
            AddToCollectionSheet(movieId: item.id).presentationDetents([.medium, .large])
        }
        .onAppear(perform: loadCollections)
        .task(id: item.id) {
            guard let watch = app.watchTogether(itemId: item.id) else { return }
            let (catalogModel, browser, item) = (model, browser, item)
            watch.onStart = { [weak watch] ms in
                if let watch { browser.play(item, in: catalogModel.catalog, from: ms, together: watch) }
            }
            together = watch
            await watch.run()
        }
        .task(id: item.id) {
            await cuts.load(item.id, from: model)
            credits = await model.credits(item.id)
        }
        .task(id: item.id) { related = await model.related(item.id) }
        // Another title in this same page shows nothing of the last one's while its own loads.
        .onChange(of: item.id) { related = nil }
        .onChange(of: cuts.file?.id) { audioTrackId = media?.defaultAudio?.id }
        .task(id: "\(item.id) \(capabilities.path)") {
            if let endpoint = app.endpoint {
                verdict = await model.playability(item.id, facts: capabilities.facts(), server: endpoint)?.verdict
            }
        }
    }

    private func episodeHeader(_ meta: MetaLine, _ progress: Double?, _ catalog: Catalog) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ArtBlock(item: item, aspect: 16 / 9, radius: 10)
                .overlay(alignment: .bottom) { if let progress { ProgressBar(value: progress, height: 4) } }
            VStack(alignment: .leading, spacing: 4) {
                if let show = catalog.show(of: item), let season = catalog.parent(of: item) {
                    Button("\(Catalog.title(show)) · \(Catalog.title(season))") { browser.open(season) }
                        .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                Text("\(item.episodeNumber ?? 0). \(Catalog.title(item))").font(.system(size: 24, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                meta.padding(.top, 2)
            }
            VStack(spacing: 10) { actions(catalog) }
            togetherNotice
            if let overview = item.metadata?.overview {
                Text(overview).font(.system(size: 14)).foregroundStyle(Theme.synopsis)
            }
        }
    }

    private var media: MediaSummary? { cuts.file.map(MediaSummary.init) }

    /// The edition choice too, which Watch together hides since it plays the default.
    @ViewBuilder
    private var togetherNotice: some View {
        if together?.current == nil { EditionPicker(cuts: cuts) }
        if let together { TogetherNotice(model: together, title: Catalog.title(item)) }
    }

    @ViewBuilder
    private func actions(_ catalog: Catalog) -> some View {
        let inProgress = cuts.resumes(catalog.watch[item.id])
        let shared = together?.inSync == true ? together : nil
        let sent = cuts.sent(together: together?.current != nil)
        Button {
            // Plays for both; each side's player opens as the shared state turns to playing.
            if let shared {
                Task { await shared.playTogether() }
            } else {
                browser.play(item, in: catalog, audioTrackId: audioTrackId, edition: sent)
            }
        } label: {
            Label(shared != nil ? "Play together" : inProgress ? "Resume" : "Play", systemImage: "play.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(PrimaryButtonStyle(fullWidth: true)).needsServer(.play, item.id)
        HStack(spacing: 10) {
            if inProgress && shared == nil {
                Button {
                    browser.play(item, in: catalog, audioTrackId: audioTrackId, edition: sent, from: 0)
                } label: {
                    Text("Start over").frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle(fullWidth: true)).needsServer(.play, item.id)
            }
            ItemMoreMenu(
                item: item, together: together, editionId: cuts.sent(together: false) ?? nil, target: $addTarget,
                addToCollection: item.kind == .movie ? { collecting = true } : nil)
        }
        NeighborButtons(related: related)
    }

    @ViewBuilder
    private func details(episode: Bool) -> some View {
        let crew = credits?.crewLines ?? []
        if media != nil || !crew.isEmpty || !collections.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Details").font(.system(size: 17, weight: .bold))
                if !collections.isEmpty { CollectionLinks(collections: collections) }
                ForEach(crew, id: \.0) { job, names in KeyValue(key: job, value: names) }
                if !episode, let genres = item.genres, !genres.isEmpty {
                    KeyValue(key: "Genres", value: genres.map(\.name).joined(separator: ", "))
                }
                if let media { mediaLines(media, episode: episode) }
            }
        }
    }

    /// Only a movie's own details name its collections, so they are read again after Add to collection.
    private func loadCollections() {
        guard item.kind == .movie else { return }
        Task { collections = await services.collections.collections(of: item.id) }
    }

    @ViewBuilder
    private func mediaLines(_ media: MediaSummary, episode: Bool) -> some View {
        if !episode, media.audio.count > 1 {
            KeyValue(key: "Audio") {
                Picker("Audio track", selection: $audioTrackId) {
                    ForEach(media.audio) { Text(media.label($0)).tag(Optional($0.id)) }
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()
            }
        } else if let audio = media.defaultAudio {
            KeyValue(key: "Audio", value: media.label(audio))
        }
        if !media.subtitles.isEmpty { KeyValue(key: "Subtitles", value: media.subtitleLine) }
        if let video = media.videoLine {
            KeyValue(key: "Video") {
                if let verdict {
                    let label = Text(Format.verdict(verdict))
                        .foregroundStyle(verdict == .directPlay ? Theme.green : Theme.amber)
                    Text("\(video) · \(label) on this device")
                } else {
                    Text(video)
                }
            }
        }
        if !episode {
            KeyValue(key: "File") { Text(media.fileLine).foregroundStyle(Theme.secondary) }
        }
    }
}

/// A show or a season: its children and a Resume for the right episode.
struct GroupDetail: View {
    @Environment(CatalogModel.self) private var model
    @Environment(Browser.self) private var browser
    @Environment(AppModel.self) private var app
    let item: Item
    @State private var credits: Credits?
    @State private var addTarget: PlaylistTarget?

    var body: some View {
        let catalog = model.catalog
        let target = catalog.resumeTarget(for: item.id)
        let unwatched = catalog.unwatchedCount(item.id)
        let show = item.kind == .show
        let children = catalog.children(of: item.id)
        let left = target.flatMap { target in
            catalog.remainingMs(target.id).map { "\(Format.remaining(ms: $0)) in \(Format.episodeCode(target))" }
        }
        DetailHeader(
            item: item, title: Catalog.title(item), posterWidth: show ? 120 : 100,
            meta: MetaLine(
                parts: show
                    ? [
                        catalog.caption(item), Catalog.year(item).map { "\($0)–" } ?? "",
                        item.metadata?.contentRating ?? "",
                    ]
                    : [
                        "\(children.count) episodes", "\(unwatched) unwatched",
                        Catalog.year(item).map(String.init) ?? "",
                    ],
                left: show ? left : nil),
            genres: show, progress: catalog.resumeProgress(item.id)
        ) {
            if let target {
                let episodes = catalog.episodes(under: item.id)
                PlayShuffle(
                    playTitle: resumeTitle(target, catalog), id: target.id, play: { browser.play(target, in: catalog) },
                    shuffle: episodes.contains(where: VideoQueue.shuffles)
                        ? { browser.shuffle(episodes, downloads: app.downloads, profile: model.profileId) } : nil)
            }
            HStack(spacing: 10) {
                if show,
                    let season = children.first(where: { $0.id == target?.parentId })
                        ?? children.first(where: { $0.kind == .season })
                {
                    Button {
                        browser.open(season)
                    } label: {
                        Text("Episodes").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryButtonStyle(fullWidth: true))
                }
                ItemMoreMenu(item: item, target: $addTarget)
            }
        }
        .navigationTitle(show ? Catalog.title(item) : "")
        .addToPlaylist($addTarget)
        VStack(alignment: .leading, spacing: show ? 12 : 0) {
            Text(show ? "Seasons" : "Episodes").font(.system(size: 17, weight: .bold)).padding(.bottom, show ? 0 : 4)
            if show {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) { ForEach(children) { SeasonTile(item: $0) } }
                }
            } else {
                ForEach(children) { EpisodeRow(item: $0, current: $0.id == target?.id) }
            }
        }
        .task(id: item.id) { if show { credits = await model.credits(item.id) } }
        if let credits {
            if !credits.cast.isEmpty { CastRow(credits: credits) }
            let crew = credits.crewLines
            if !crew.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Details").font(.system(size: 17, weight: .bold))
                    ForEach(crew, id: \.0) { job, names in KeyValue(key: job, value: names) }
                }
            }
        }
    }

    private func resumeTitle(_ target: Item, _ catalog: Catalog) -> String {
        let code = item.kind == .show ? Format.episodeCode(target) : "E\(target.episodeNumber ?? 0)"
        return catalog.isInProgress(target.id) ? "Resume \(code)" : "Play \(code)"
    }
}
