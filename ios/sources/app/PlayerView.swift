import AVKit
import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// The full-screen player. The model and its AVPlayer are built once per
/// request, not on every re-render of the browsing views behind it.
struct PlayerScreen: View {
    let request: PlayRequest
    let client: Client
    let endpoint: ServerEndpoint
    let profileId: UID
    let close: () -> Void
    @State private var model: PlayerModel?
    @State private var output: AVPlayerOutput?
    @State private var capabilities: SystemCapabilities?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let model, let output, let capabilities {
                PlayerSurface(
                    request: request, close: close, model: model, output: output, capabilities: capabilities)
            }
        }
        .task {
            // Plays with the ringer off and keeps playing in picture in picture and over AirPlay.
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            let output = AVPlayerOutput()
            let capabilities = AppContext.shared.capabilities
            let model = PlayerModel(
                client: client, endpoint: endpoint, profileId: profileId, item: request.item, output: output,
                capabilities: capabilities, device: "iPhone", playlistId: request.queue?.playlistId)
            self.output = output
            self.capabilities = capabilities
            self.model = model
            await model.start(request)
        }
        .onDisappear { request.together?.detach() }
    }
}

struct PlayerSurface: View {
    enum Popup { case quality, subtitles }

    @Environment(AppModel.self) private var app
    @Environment(CatalogModel.self) private var catalog
    @Environment(Browser.self) private var browser
    @Environment(\.scenePhase) private var scenePhase
    let request: PlayRequest
    let close: () -> Void
    let model: PlayerModel
    let output: AVPlayerOutput
    let capabilities: SystemCapabilities
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showControls = true
    @State private var controlsGone = false
    @State private var lastActivity = Date()
    @State private var scrubbing: Double?
    @State private var popup: Popup?
    @State private var pip: AVPictureInPictureController?
    @State private var upNext: UpNextModel?

    var body: some View {
        // Read once per render, not on every tick of the timeline below.
        let next = catalog.catalog.nextEpisode(after: request.item)
        ZStack {
            Color.black.ignoresSafeArea()
            VideoSurface(player: output.player, pip: $pip).ignoresSafeArea()
                .contentShape(.rect)
                .onTapGesture { showControls ? hide() : poke() }
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                let now = output.player.currentTime().seconds
                ZStack {
                    if let cue = model.cue(at: now.isFinite ? now : 0) {
                        Text(cue).font(.system(size: 18, weight: .semibold)).multilineTextAlignment(.center)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(.black.opacity(0.6), in: .rect(cornerRadius: 4))
                            .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, showControls ? 110 : 30)
                            .allowsHitTesting(false)
                    }
                    if !controlsGone { controls(now: now, next: next).opacity(showControls ? 1 : 0) }
                }
            }
            if let notice = request.together?.pausedNotice {
                Label(notice, systemImage: "pause.fill").font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Theme.ground.opacity(0.92), in: .rect(cornerRadius: 10))
                    .frame(maxHeight: .infinity, alignment: .center).offset(y: -76)
                    .allowsHitTesting(false)
            }
            if let error = model.error {
                VStack(spacing: 12) {
                    Text(error).font(.system(size: 15, weight: .semibold)).multilineTextAlignment(.center)
                    Button("Back", action: leave).buttonStyle(SecondaryButtonStyle())
                }
                .padding(24).background(Theme.card, in: .rect(cornerRadius: 14)).padding(24)
            }
            if let upNext {
                UpNextCard(upNext: upNext, play: { playNext(upNext.request) }, cancel: leave)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(16)
            }
        }
        .foregroundStyle(Theme.primary)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task(id: lastActivity) {
            guard await ControlsFade.idle(output.player, for: ControlsFade.delay), popup == nil, scrubbing == nil
            else { return }
            if !reduceMotion { withAnimation(ControlsFade.animation) { showControls = false } }
            try? await Task.sleep(for: .seconds(ControlsFade.fade))
            if !Task.isCancelled { (showControls, controlsGone) = (false, true) }
        }
        .onChange(of: request.together?.pausedNotice) { poke() }
        // A menu holds the fade, so closing one, however it closes, is activity.
        .onChange(of: popup) { poke() }
        .onAppear { output.onEnd = ended }
        .modifier(PlayerLive(request: request, model: model, browser: browser, leave: leave, finish: finish))
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { Task { await model.reportPosition() } }
        }
    }

    private func controls(now: Double, next: Item?) -> some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.6), location: 0), .init(color: .clear, location: 0.22),
                    .init(color: .clear, location: 0.65), .init(color: .black.opacity(0.75), location: 1),
                ], startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
            VStack {
                header
                Spacer()
                center
                Spacer()
                footer(now: now, next: next)
            }
            // Inside the safe area, so the notch and home indicator stay clear in either orientation.
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            PlayerButton(icon: "chevron.left", label: "Back", action: leave)
            VStack(alignment: .leading, spacing: 2) {
                Text(catalog.catalog.playerTitle(request.item, edition: request.queue?.editionName))
                    .font(.system(size: 18, weight: .bold)).lineLimit(1).minimumScaleFactor(0.8)
                if let sub = Catalog.playerSubtitle(request.item) {
                    Text(sub).font(.system(size: 13)).foregroundStyle(Theme.synopsis)
                }
            }
            Spacer(minLength: 0)
            if let together = request.together, together.inSync, let partner = together.partnerName {
                SyncChip(partner: partner) { Task { await together.leave() } }.scaleEffect(0.85)
            }
            if pip != nil {
                PlayerButton(icon: "pip.enter", label: "Picture in picture") { pip?.startPictureInPicture() }
            }
            RoutePicker().frame(width: 44, height: 44).accessibilityLabel("AirPlay")
        }
    }

    private var center: some View {
        HStack(spacing: 40) {
            PlayerButton(icon: "gobackward.10", label: "Back 10 seconds", size: 34) { skip(-10) }
            Button(action: togglePlay) {
                Image(systemName: output.player.timeControlStatus == .paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 32)).frame(width: 72, height: 72)
                    .background(.white.opacity(0.14), in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(output.player.timeControlStatus == .paused ? "Play" : "Pause")
            PlayerButton(icon: "goforward.10", label: "Forward 10 seconds", size: 34) { skip(10) }
        }
    }

    private func footer(now: Double, next: Item?) -> some View {
        let duration = output.player.currentItem?.duration.seconds ?? 0
        let total = duration.isFinite ? duration : 0
        return VStack(spacing: 10) {
            HStack(spacing: 12) {
                Text(Format.clock(seconds: scrubbing ?? now)).monospacedDigit()
                ScrubBar(
                    position: scrubbing ?? now, duration: total, previewURL: model.previewURL(at:),
                    onScrub: {
                        scrubbing = $0
                        poke()
                    },
                    onCommit: { target in
                        seek(toMs: Int64(target * 1000))
                        scrubbing = nil
                        poke()
                    })
                Text("-" + Format.clock(seconds: total - (scrubbing ?? now))).monospacedDigit()
            }
            .font(.system(size: 13))
            .foregroundStyle(Color(hex: 0xE5E5EA))
            ZStack {
                HStack(spacing: 4) {
                    Spacer()
                    PlayerButton(icon: "captions.bubble", label: "Subtitles") { toggle(.subtitles) }
                        .overlay(alignment: .bottomTrailing) {
                            if popup == .subtitles {
                                let tracks = request.item.kind == .movie || request.item.kind == .episode
                                SubtitlesPopup(model: model, offersTracks: tracks) { popup = nil }
                                    .offset(y: -52).fixedSize()
                            }
                        }
                    if let next {
                        PlayerButton(icon: "forward.end.fill", label: "Next episode") { playNext(next) }
                    }
                }
                QualityPill(model: model, open: popup == .quality) { toggle(.quality) }
                    .overlay(alignment: .bottom) {
                        if popup == .quality {
                            QualityPopup(model: model, capabilities: capabilities) { popup = nil }
                                .offset(y: -52).fixedSize()
                        }
                    }
            }
            .frame(minHeight: 44)
        }
    }

    private func toggle(_ menu: Popup) {
        popup = popup == menu ? nil : menu
        poke()
    }

    private func poke() {
        (showControls, controlsGone) = (true, false)
        lastActivity = Date()
    }

    private func hide() {
        if popup != nil {
            popup = nil
        } else {
            (showControls, controlsGone) = (false, true)
        }
    }

    /// While in sync, play, pause and seek go through Watch together so both players follow.
    private var shared: WatchTogetherModel? { request.together?.inSync == true ? request.together : nil }

    private func togglePlay() {
        let paused = output.player.timeControlStatus == .paused
        if let shared {
            Task { paused ? await shared.play() : await shared.pause() }
        } else if paused {
            output.play()
        } else {
            output.pause()
        }
        if !paused { Task { await model.reportPosition() } }
        poke()
    }

    private func skip(_ seconds: Double) {
        seek(toMs: output.positionMs + Int64(seconds * 1000))
        poke()
    }

    private func seek(toMs ms: Int64) {
        if let shared {
            Task { await shared.seek(toMs: max(0, ms)) }
        } else {
            output.seek(toMs: max(0, ms))
        }
    }

    private var exits: PlayerExit {
        PlayerExit(request: request, model: model, catalog: catalog, browser: browser, close: close)
    }

    private func leave() { exits.leave() }

    /// The cover stays up; the browser swaps the player inside it.
    private func playNext(_ next: Item) {
        exits.finish()
        NotificationCenter.default.post(name: .playNext, object: next.id)
    }

    private func playNext(_ next: PlayRequest) { exits.playNext(next) }

    private func ended() {
        guard upNext == nil else { return }
        Task { upNext = await exits.ended(client: app.client, profile: app.activeProfile) }
    }

    private func finish() { exits.finish() }
}

extension Notification.Name {
    static let playNext = Notification.Name("enterprises.legitimate.rabbit-ears.play-next")
}

struct PlayerButton: View {
    let icon: String
    let label: String
    var size: CGFloat = 22
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size)).frame(width: 44, height: 44).contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// The card at a title's end; Autoplay, while on, counts down to the next item.
struct UpNextCard: View {
    @Environment(AppModel.self) private var app
    let upNext: UpNextModel
    let play: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Up next: \(upNext.title)").font(.system(size: 15, weight: .semibold)).lineLimit(2)
            if let left = upNext.secondsLeft {
                Text("Plays in \(left)s").font(.system(size: 13)).foregroundStyle(Theme.synopsis).monospacedDigit()
            }
            HStack(spacing: 10) {
                Button("Play now", action: play).buttonStyle(PrimaryButtonStyle())
                Button("Cancel", action: cancel).buttonStyle(SecondaryButtonStyle())
            }
            Toggle(
                "Autoplay",
                isOn: Binding(
                    get: { upNext.autoplay }, set: { on in Task { await upNext.setAutoplay(on, model: app) } })
            )
            .font(.system(size: 14))
            .tint(Theme.amber)
        }
        .padding(16)
        .frame(maxWidth: 360, alignment: .leading)
        .background(Theme.card, in: .rect(cornerRadius: 12))
        .task(id: upNext.autoplay) { if await upNext.countdown() { play() } }
    }
}
