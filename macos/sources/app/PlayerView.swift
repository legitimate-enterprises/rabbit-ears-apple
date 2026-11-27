import AVKit
import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// The full-window player. The model and its AVPlayer are built once per
/// request, not on every re-render of the browsing views behind it.
struct PlayerScreen: View {
    let request: PlayRequest
    let client: Client
    let endpoint: ServerEndpoint
    let profileId: Int64
    let capabilities: SystemCapabilities
    let close: () -> Void
    @State private var model: PlayerModel?
    @State private var output: AVPlayerOutput?

    var body: some View {
        ZStack {
            Color.black
            if let model, let output { PlayerSurface(request: request, close: close, model: model, output: output) }
        }
        .ignoresSafeArea()
        .task {
            let output = AVPlayerOutput()
            let model = PlayerModel(
                client: client, endpoint: endpoint, profileId: profileId, item: request.item, output: output,
                capabilities: capabilities, playlistId: request.queue?.playlistId)
            self.output = output
            self.model = model
            await model.start(
                audioTrackId: request.audioTrackId, editionId: request.editionId, positionMs: request.positionMs)
            request.together?.attach(output)
        }
    }
}

struct PlayerSurface: View {
    @Environment(AppModel.self) private var app
    @Environment(CatalogModel.self) private var catalog
    @Environment(Browser.self) private var browser
    let request: PlayRequest
    let close: () -> Void
    let model: PlayerModel
    let output: AVPlayerOutput
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showControls = true
    @State private var controlsGone = false
    @State private var lastActivity = Date()
    @State private var scrubbing: Double?
    @State private var muted = false
    @AppStorage(Volume.key) private var volume = Volume.initial
    @FocusState private var focused: Bool
    @State private var upNext: UpNextModel?
    @State private var pip: AVPictureInPictureController?

    var body: some View {
        ZStack {
            Color.black
            VideoSurface(player: output.player, pip: $pip)
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                let now = output.player.currentTime().seconds
                ZStack {
                    if let cue = model.cue(at: now.isFinite ? now : 0) {
                        Text(cue).font(.system(size: 22, weight: .semibold)).multilineTextAlignment(.center)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(.black.opacity(0.6), in: .rect(cornerRadius: 4))
                            .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, showControls ? 120 : 40)
                    }
                    if !controlsGone { controls(now: now).opacity(showControls ? 1 : 0) }
                }
            }
            if let error = model.error {
                VStack(spacing: 12) {
                    Text(error).font(.system(size: 15, weight: .semibold))
                    Button("Back", action: leave).buttonStyle(SecondaryButtonStyle())
                }
                .padding(24).background(Theme.card, in: .rect(cornerRadius: 14))
            }
            if let upNext {
                UpNextCard(upNext: upNext, play: { playNext(upNext.request) }, cancel: leave)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(28)
            }
        }
        .foregroundStyle(Color(hex: 0xF2F2F7))
        .ignoresSafeArea()
        .onContinuousHover { _ in poke() }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(action: key)
        .onAppear {
            focused = true
            output.onEnd = ended
        }
        // The replaced player's disappearance ends its session, so there is nothing for `finish` to do.
        .modifier(PlayerLive(request: request, model: model, browser: browser, leave: leave, finish: {}))
        .task(id: lastActivity) {
            try? await Task.sleep(for: .seconds(ControlsFade.delay))
            guard !Task.isCancelled, output.player.timeControlStatus == .playing else { return }
            if !reduceMotion { withAnimation(ControlsFade.animation) { showControls = false } }
            try? await Task.sleep(for: .seconds(ControlsFade.fade))
            if !Task.isCancelled { (showControls, controlsGone) = (false, true) }
        }
    }

    private func controls(now: Double) -> some View {
        VStack {
            header
            Spacer()
            VStack(spacing: 18) {
                if let notice = request.together?.pausedNotice { TogetherNotice(text: notice) }
                center
            }
            Spacer()
            footer(now: now)
        }
        .background(
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.6), location: 0), .init(color: .clear, location: 0.22),
                    .init(color: .clear, location: 0.65), .init(color: .black.opacity(0.75), location: 1),
                ], startPoint: .top, endPoint: .bottom)
        )
    }

    private var header: some View {
        HStack(spacing: 12) {
            PlayerButton(icon: "chevron.left", label: "Back", action: leave)
            VStack(alignment: .leading, spacing: 2) {
                Text(catalog.catalog.playerTitle(request.item, edition: request.queue?.editionName))
                    .font(.system(size: 18, weight: .bold))
                if let sub = Catalog.playerSubtitle(request.item) {
                    Text(sub).font(.system(size: 13)).foregroundStyle(Theme.synopsis)
                }
            }
            Spacer()
            if let together = request.together { TogetherPlayerChip(together: together) }
            if pip != nil {
                PlayerButton(icon: "pip.enter", label: "Picture in picture") { pip?.startPictureInPicture() }
            }
            RoutePicker(player: output.player).frame(width: 44, height: 44).accessibilityLabel("AirPlay")
        }
        // Clears the title bar's window buttons, which stay over the video.
        .padding(EdgeInsets(top: 40, leading: 20, bottom: 0, trailing: 20))
    }

    private var center: some View {
        HStack(spacing: 40) {
            PlayerButton(icon: "gobackward.10", label: "Back 10 seconds", size: 28) { skip(-10) }
            Button(action: togglePlay) {
                Image(systemName: output.player.timeControlStatus == .paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 30)).frame(width: 72, height: 72)
                    .background(.white.opacity(0.14), in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(output.player.timeControlStatus == .paused ? "Play" : "Pause")
            PlayerButton(icon: "goforward.10", label: "Forward 10 seconds", size: 28) { skip(10) }
        }
    }

    private func footer(now: Double) -> some View {
        let duration = output.player.currentItem?.duration.seconds ?? 0
        let total = duration.isFinite ? duration : 0
        return VStack(spacing: 10) {
            HStack(spacing: 12) {
                Text(Format.clock(seconds: scrubbing ?? now)).monospacedDigit()
                ScrubBar(
                    position: scrubbing ?? now, duration: total, previewURL: model.previewURL(at:),
                    onScrub: { scrubbing = $0 },
                    onCommit: { target in
                        seek(toMs: Int64(target * 1000))
                        scrubbing = nil
                    })
                Text("-" + Format.clock(seconds: total - (scrubbing ?? now))).monospacedDigit()
            }
            .font(.system(size: 13))
            ZStack {
                HStack(spacing: 6) {
                    PlayerButton(icon: muted ? "speaker.slash.fill" : "speaker.wave.2.fill", label: "Mute") {
                        muted.toggle()
                        output.player.isMuted = muted
                    }
                    Slider(value: $volume, in: 0...1).frame(width: 90).accessibilityLabel("Volume")
                        .onChange(of: volume, initial: true) { output.player.volume = Float(volume) }
                    Spacer()
                    SubtitlesMenu(
                        model: model, offersTracks: request.item.kind == .movie || request.item.kind == .episode)
                    if let next = catalog.catalog.nextEpisode(after: request.item) {
                        PlayerButton(icon: "forward.end.fill", label: "Next episode") { playNext(next) }
                    }
                    PlayerButton(icon: "arrow.up.left.and.arrow.down.right", label: "Full screen") {
                        NSApp.keyWindow?.toggleFullScreen(nil)
                    }
                }
                QualityMenu(model: model)
            }
            .frame(minHeight: 44)
        }
        .padding(EdgeInsets(top: 0, leading: 20, bottom: 16, trailing: 20))
    }

    private func poke() {
        (showControls, controlsGone) = (true, false)
        lastActivity = Date()
    }

    /// While in sync, play, pause and seek go through Watch together so
    /// both sides apply them; otherwise straight to the player.
    private var together: WatchTogetherModel? {
        request.together?.inSync == true ? request.together : nil
    }

    private func togglePlay() {
        let paused = output.player.timeControlStatus == .paused
        if let together {
            Task {
                if paused { await together.play() } else { await together.pause() }
                if !paused { await model.reportPosition() }
            }
        } else if paused {
            output.play()
        } else {
            output.pause()
            Task { await model.reportPosition() }
        }
        poke()
    }

    private func skip(_ seconds: Double) {
        seek(toMs: max(0, output.positionMs + Int64(seconds * 1000)))
        poke()
    }

    private func seek(toMs ms: Int64) {
        if let together {
            Task { await together.seek(toMs: ms) }
        } else {
            output.seek(toMs: ms)
        }
    }

    /// Leaving the player leaves a Watch together that is in sync, or the
    /// details page behind would open the player again at the next poll.
    /// The leave has a task of its own, so the player stops without waiting
    /// on the server's answer to it.
    private func endPlayback() {
        let id = request.item.id
        let together = request.together
        if together?.inSync == true { Task { await together?.leave() } }
        Task {
            together?.detach()
            await model.stop()
            await catalog.refreshWatchState(id)
            browser.revision += 1
        }
        close()
    }

    private func leave() { endPlayback() }

    private func playNext(_ next: Item) {
        endPlayback()
        DispatchQueue.main.async { NotificationCenter.default.post(name: .playNext, object: next.id) }
    }

    /// What Up next plays, in a player of its own.
    private func playNext(_ next: PlayRequest) {
        endPlayback()
        var fresh = next
        fresh.id = UUID()
        DispatchQueue.main.async { browser.playing = fresh }
    }

    private func ended() {
        guard upNext == nil else { return }
        guard let replica = app.sync?.replica, let profile = app.activeProfile else { return leave() }
        Task {
            if let next = await UpNextModel.load(after: request, replica: replica, profile: profile) {
                upNext = next
            } else {
                leave()
            }
        }
    }

    private func key(_ press: KeyPress) -> KeyPress.Result {
        poke()
        // Command keys belong to the menus, as Cmd-F to Search.
        guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
        switch press.key {
        case .space: togglePlay()
        case .leftArrow: skip(press.modifiers.contains(.shift) ? -30 : -10)
        case .rightArrow: skip(press.modifiers.contains(.shift) ? 30 : 10)
        case .upArrow: volume = min(1, volume + 0.1)
        case .downArrow: volume = max(0, volume - 0.1)
        case .escape: escape()
        default: return letter(press.characters.lowercased())
        }
        return .handled
    }

    private func letter(_ characters: String) -> KeyPress.Result {
        switch characters {
        case "m":
            muted.toggle()
            output.player.isMuted = muted
        case "f": NSApp.keyWindow?.toggleFullScreen(nil)
        case "c":
            let tracks = request.item.kind == .movie || request.item.kind == .episode
            Task { await model.nextSubtitles(offeringTracks: tracks) }
        default: return .ignored
        }
        return .handled
    }

    private func escape() {
        if NSApp.keyWindow?.styleMask.contains(.fullScreen) == true {
            NSApp.keyWindow?.toggleFullScreen(nil)
        } else {
            leave()
        }
    }
}

extension Notification.Name {
    static let playNext = Notification.Name("enterprises.legitimate.rabbit-ears.play-next")
}

struct PlayerButton: View {
    let icon: String
    let label: String
    var size: CGFloat = 18
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size)).frame(width: 44, height: 44).contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

struct RoutePicker: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.player = player
        view.isRoutePickerButtonBordered = false
        return view
    }

    func updateNSView(_ view: AVRoutePickerView, context: Context) {}
}

/// The card at a title's end; it counts down to the next item while Autoplay is on.
struct UpNextCard: View {
    @Environment(AppModel.self) private var app
    let upNext: UpNextModel
    let play: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Up next: \(upNext.title)").font(.system(size: 15, weight: .semibold)).lineLimit(2)
            if let left = upNext.secondsLeft {
                Text("Plays in \(left)s").font(.system(size: 13)).foregroundStyle(Theme.synopsis).monospacedDigit()
            }
            HStack(spacing: 10) {
                Button("Play now", action: play).buttonStyle(PrimaryButtonStyle())
                Button("Cancel", action: cancel).buttonStyle(SecondaryButtonStyle())
                Toggle(
                    "Autoplay",
                    isOn: Binding(
                        get: { upNext.autoplay },
                        set: { on in Task { await upNext.setAutoplay(on, model: app) } })
                )
                .toggleStyle(.checkbox)
            }
        }
        .padding(16)
        .frame(maxWidth: 420, alignment: .leading)
        .background(Theme.card, in: .rect(cornerRadius: 12))
        .task(id: upNext.autoplay) { if await upNext.countdown() { play() } }
    }
}
