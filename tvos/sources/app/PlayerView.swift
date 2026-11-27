import AVFoundation
import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// The model and its AVPlayer are built once per request, not on every
/// re-render of the browsing views behind it.
struct PlayerScreen: View {
    let request: PlayRequest
    let client: Client
    let endpoint: ServerEndpoint
    let profileId: UID
    let capabilities: SystemCapabilities
    let close: () -> Void
    @State private var model: PlayerModel?
    @State private var output: AVPlayerOutput?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let model, let output { PlayerSurface(request: request, close: close, model: model, output: output) }
        }
        .task {
            let output = AVPlayerOutput()
            let model = PlayerModel(
                client: client, endpoint: endpoint, profileId: profileId, item: request.item, output: output,
                capabilities: capabilities, device: "Apple TV", playlistId: request.queue?.playlistId)
            self.output = output
            self.model = model
            await model.start(request)
        }
        .onDisappear { request.together?.detach() }
    }
}

/// Focus rests on an invisible surface standing for the seek bar.
struct PlayerSurface: View {
    enum Popup { case quality, subtitles }
    enum Focus: Hashable {
        case surface, pill, subtitles, next
        case option(Int)
    }

    @Environment(AppModel.self) private var app
    @Environment(CatalogModel.self) private var catalog
    @Environment(Browser.self) private var browser
    @Environment(\.scenePhase) private var scenePhase
    let request: PlayRequest
    let close: () -> Void
    let model: PlayerModel
    let output: AVPlayerOutput
    @State private var upNext: UpNextModel?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showControls = true
    @State private var controlsGone = false
    @State private var lastActivity = Date()
    @State private var scrubbing: Double?
    @State private var popup: Popup?
    @FocusState private var focus: Focus?

    /// Seconds scrubbed by one press of left or right.
    static let step = 10.0

    var body: some View {
        // Read once per render, not on every tick of the timeline below.
        let next = catalog.catalog.nextEpisode(after: request.item)
        ZStack {
            VideoLayer(player: output.player).ignoresSafeArea()
            Button(action: select) { Color.clear }
                .buttonStyle(BareButtonStyle())
                .focused($focus, equals: .surface)
                .onMoveCommand(perform: move)
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                let now = output.player.currentTime().seconds
                let position = now.isFinite ? now : 0
                ZStack {
                    if let cue = model.cue(at: position) {
                        Text(cue).font(.system(size: 44, weight: .semibold)).multilineTextAlignment(.center)
                            .padding(.horizontal, 20).padding(.vertical, 8)
                            .background(.black.opacity(0.6), in: .rect(cornerRadius: 8))
                            .frame(maxHeight: .infinity, alignment: .bottom)
                            .padding(.bottom, showControls || scrubbing != nil ? 300 : 90)
                            .allowsHitTesting(false)
                    }
                    if !controlsGone || scrubbing != nil {
                        controls(position: scrubbing ?? position, next: next)
                            .opacity(showControls || scrubbing != nil ? 1 : 0)
                    }
                }
            }
            if let notice = request.together?.pausedNotice, let name = request.together?.partnerName {
                PausedNotice(text: notice, name: name).allowsHitTesting(false)
            }
            if let error = model.error {
                VStack(spacing: 30) {
                    Text(error).font(.system(size: 34, weight: .semibold)).multilineTextAlignment(.center)
                    Button("Back", action: leave).buttonStyle(TVButtonStyle())
                }
                .padding(60).background(Theme.card, in: .rect(cornerRadius: 28))
            }
            if let upNext {
                UpNextCard(upNext: upNext, play: { playNext(upNext.request) }, cancel: leave)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(Theme.safeArea)
            }
        }
        .foregroundStyle(Theme.light)
        .defaultFocus($focus, .surface)
        .onPlayPauseCommand(perform: togglePlay)
        .onExitCommand(perform: back)
        .onAppear { output.onEnd = ended }
        .modifier(PlayerLive(request: request, model: model, browser: browser, leave: leave, finish: finish))
        .task(id: lastActivity) {
            try? await Task.sleep(for: .seconds(ControlsFade.remoteDelay))
            guard !Task.isCancelled, popup == nil, scrubbing == nil, output.player.timeControlStatus == .playing
            else { return }
            if !reduceMotion { withAnimation(ControlsFade.animation) { showControls = false } }
            try? await Task.sleep(for: .seconds(ControlsFade.fade))
            if !Task.isCancelled { hideControls() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { Task { await model.reportPosition() } }
        }
    }

    private func controls(position: Double, next: Item?) -> some View {
        let duration = output.player.currentItem?.duration.seconds ?? 0
        let total = duration.isFinite ? duration : 0
        return ZStack(alignment: .bottom) {
            LinearGradient(
                stops: [.init(color: .clear, location: 0.45), .init(color: .black.opacity(0.85), location: 1)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 0) {
                if let popup {
                    Group {
                        switch popup {
                        case .quality: QualityMenu(model: model, focus: $focus) { close(.pill) }
                        case .subtitles: SubtitlesMenu(model: model, focus: $focus) { close(.subtitles) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.bottom, 24)
                    .focusSection()
                }
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 20) {
                            Text(catalog.catalog.playerTitle(request.item, edition: request.queue?.editionName))
                                .font(.system(size: 52, weight: .bold)).lineLimit(1)
                            if let together, let name = together.partnerName { SyncChip(name: name) }
                            if output.player.timeControlStatus == .paused || scrubbing != nil { Tag(text: "Paused") }
                        }
                        if let subtitle = Catalog.playerSubtitle(request.item) {
                            Text(subtitle).font(.system(size: 30)).foregroundStyle(Theme.synopsis)
                        }
                    }
                    Spacer(minLength: 40)
                    if scrubbing == nil { buttons(next: next) }
                }
                ScrubTrack(
                    position: position, duration: total, scrubbing: scrubbing != nil,
                    preview: scrubbing.flatMap { model.previewURL(at: $0) }
                )
                .padding(.top, 26)
                HStack {
                    Text(Format.clock(seconds: position)).monospacedDigit()
                    Spacer()
                    if scrubbing != nil {
                        Text("Swipe to scrub, click to play from here").foregroundStyle(Theme.secondary)
                        Spacer()
                    } else if together != nil {
                        Text("Back leaves Watch together").font(.system(size: 28)).foregroundStyle(Theme.secondary)
                        Spacer()
                    }
                    Text("-" + Format.clock(seconds: total - position)).monospacedDigit()
                }
                .font(.system(size: 30))
                .padding(.top, 24)
            }
            .padding(Theme.safeArea)
        }
    }

    private func buttons(next: Item?) -> some View {
        HStack(spacing: 20) {
            Button {
                open(.quality)
            } label: {
                QualityPill(model: model)
            }
            .focused($focus, equals: .pill)
            .accessibilityLabel("Playback quality: \(model.pill)")
            Button {
                open(.subtitles)
            } label: {
                Label("Subtitles", systemImage: "captions.bubble")
            }
            .focused($focus, equals: .subtitles)
            if let next {
                Button {
                    playNext(next)
                } label: {
                    Label("Next episode", systemImage: "forward.end.fill")
                }
                .focused($focus, equals: .next)
            }
        }
        .buttonStyle(PlayerButtonStyle())
        .focusSection()
        .onMoveCommand { if $0 == .down, popup == nil { focus = .surface } }
    }

    private func select() {
        guard let target = scrubbing else { return togglePlay() }
        if let together {
            Task {
                await together.seek(toMs: Int64(target * 1000))
                await together.play()
            }
        } else {
            output.seek(toMs: Int64(target * 1000))
            output.play()
        }
        scrubbing = nil
        poke()
    }

    private func move(_ direction: MoveCommandDirection) {
        switch direction {
        case .left, .right:
            let duration = output.player.currentItem?.duration.seconds ?? 0
            let now = scrubbing ?? output.player.currentTime().seconds
            guard duration.isFinite, duration > 0, now.isFinite else { return }
            if scrubbing == nil { pause() }
            scrubbing = min(duration, max(0, now + (direction == .left ? -Self.step : Self.step)))
            poke()
        case .up where showControls && scrubbing == nil: focus = .pill
        default: poke()
        }
    }

    private func togglePlay() {
        if scrubbing != nil { return select() }
        if output.player.timeControlStatus == .paused { play() } else { pause() }
        poke()
    }

    private func back() {
        if upNext != nil {
            leave()
        } else if let open = popup {
            close(open == .quality ? .pill : .subtitles)
        } else if scrubbing != nil {
            scrubbing = nil
            play()
            poke()
        } else if focus != .surface {
            focus = .surface
            poke()
        } else {
            leave()
        }
    }

    private func open(_ menu: Popup) {
        popup = menu
        poke()
        // Focus moves once the menu's rows exist.
        Task { focus = .option(menu.selected(in: model)) }
    }

    private func close(_ button: Focus) {
        popup = nil
        focus = button
        poke()
    }

    private func poke() {
        (showControls, controlsGone) = (true, false)
        lastActivity = Date()
    }

    private func hideControls() {
        popup = nil
        (showControls, controlsGone) = (false, true)
        focus = .surface
    }

    private var exits: PlayerExit {
        PlayerExit(request: request, model: model, catalog: catalog, browser: browser, close: close)
    }

    private func leave() { exits.leave() }

    /// The cover stays up; the browser swaps the player inside it.
    private func playNext(_ next: Item) {
        exits.finish()
        browser.playNext(next)
    }

    private func playNext(_ next: PlayRequest) { exits.playNext(next) }

    private func ended() {
        guard upNext == nil else { return }
        Task { upNext = await exits.ended(client: app.client, profile: app.activeProfile) }
    }

    private func finish() { exits.finish() }
}

extension PlayerSurface {
    /// While in sync, play, pause and seek go to the other member too, and the model applies them here.
    private var together: WatchTogetherModel? { request.together?.inSync == true ? request.together : nil }

    private func play() {
        if let together { Task { await together.play() } } else { output.play() }
    }

    private func pause() {
        if let together { Task { await together.pause() } } else { output.pause() }
        Task { await model.reportPosition() }
    }
}

struct UpNextCard: View {
    enum Choice: Hashable { case play, cancel, autoplay }

    @Environment(AppModel.self) private var app
    let upNext: UpNextModel
    let play: () -> Void
    let cancel: () -> Void
    @FocusState private var focus: Choice?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Up next: \(upNext.title)").font(.system(size: 38, weight: .semibold)).lineLimit(2)
            if let left = upNext.secondsLeft {
                Text("Plays in \(left)s").font(.system(size: 29)).foregroundStyle(Theme.synopsis).monospacedDigit()
            }
            HStack(spacing: 24) {
                Button("Play now", action: play).focused($focus, equals: .play)
                Button("Cancel", action: cancel).focused($focus, equals: .cancel)
                Button {
                    Task { await upNext.setAutoplay(!upNext.autoplay, model: app) }
                } label: {
                    Label("Autoplay", systemImage: upNext.autoplay ? "checkmark.square.fill" : "square")
                }
                .focused($focus, equals: .autoplay)
                .accessibilityValue(upNext.autoplay ? "On" : "Off")
            }
            .buttonStyle(TVButtonStyle())
        }
        .padding(48)
        .frame(maxWidth: 1100, alignment: .leading)
        .background(Theme.card, in: .rect(cornerRadius: 28))
        .focusSection()
        .defaultFocus($focus, .play)
        .onAppear { focus = .play }
        .task(id: upNext.autoplay) { if await upNext.countdown() { play() } }
    }
}
