import AVFoundation
import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

extension View {
    /// The station player takes the speakers from the music.
    func stationCover(
        browser: Browser, music: RabbitEarsKit.MusicPlayer?, capabilities: SystemCapabilities
    ) -> some View {
        modifier(StationCover(browser: browser, music: music, capabilities: capabilities))
    }
}

private struct StationCover: ViewModifier {
    @Environment(AppModel.self) private var app
    @Bindable var browser: Browser
    let music: RabbitEarsKit.MusicPlayer?
    let capabilities: SystemCapabilities

    func body(content: Content) -> some View {
        content.fullScreenCover(item: $browser.tuning) { station in
            if let client = app.client, let endpoint = app.endpoint, let profile = app.activeProfile {
                StationPlayerScreen(
                    station: station, client: client, endpoint: endpoint, profileId: profile.id,
                    capabilities: capabilities, close: { browser.tuning = nil }
                )
                .id(station.id)
                .onAppear { Task { await music?.pause() } }
            }
        }
    }
}

/// The model, its AVPlayer and the tuner live as long as the cover; closing
/// it, however it closes, leaves the station.
struct StationPlayerScreen: View {
    let station: Station
    let client: Client
    let endpoint: ServerEndpoint
    let profileId: Int64
    let capabilities: SystemCapabilities
    let close: () -> Void
    @State private var model: PlayerModel?
    @State private var output: AVPlayerOutput?
    @State private var tuner: StationTuner?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let model, let output, let tuner {
                StationSurface(model: model, output: output, tuner: tuner, close: close)
            }
        }
        .task {
            let output = AVPlayerOutput()
            let model = PlayerModel(
                client: client, endpoint: endpoint, profileId: profileId, item: nil, output: output,
                capabilities: capabilities, device: "Apple TV")
            let tuner = StationTuner(client: client, station: station)
            self.output = output
            self.model = model
            self.tuner = tuner
            await model.tune(tuner, on: output)
        }
        .onDisappear { Task { await model?.stop() } }
        .onChange(of: scenePhase) { _, phase in if phase == .active { tuner?.resume() } }
    }
}

/// Nothing pauses, seeks or skips: play/pause and swipes only bring the controls up.
struct StationSurface: View {
    typealias Focus = PlayerSurface.Focus

    let model: PlayerModel
    let output: AVPlayerOutput
    let tuner: StationTuner
    let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showControls = true
    @State private var controlsGone = false
    @State private var lastActivity = Date()
    @State private var popup: PlayerSurface.Popup?
    @FocusState private var focus: Focus?

    var body: some View {
        let station = tuner.station
        ZStack {
            if tuner.offAir {
                Theme.ground.ignoresSafeArea()
                VStack(spacing: 0) {
                    if station.imageUrl != nil {
                        StationIdentity(name: station.name, aspect: 1, imageUrl: station.imageUrl).frame(width: 360)
                    } else {
                        StationGlyph(size: 146)
                    }
                    Text(station.name).font(.system(size: 76, weight: .bold)).padding(.top, 60)
                    Text(StationText.waiting(station.onAir, kind: station.kind)).font(.system(size: 36))
                        .foregroundStyle(Theme.synopsis).padding(.top, 20)
                }
            } else {
                VideoLayer(player: output.player).ignoresSafeArea()
            }
            Button(action: poke) { Color.clear }
                .buttonStyle(BareButtonStyle())
                .focused($focus, equals: .surface)
                .onMoveCommand(perform: move)
            if !tuner.offAir {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let seconds = output.player.currentTime().seconds
                    ZStack {
                        if let cue = model.cue(at: seconds.isFinite ? seconds : 0) {
                            Text(cue).font(.system(size: 44, weight: .semibold)).multilineTextAlignment(.center)
                                .padding(.horizontal, 20).padding(.vertical, 8)
                                .background(.black.opacity(0.6), in: .rect(cornerRadius: 8))
                                .frame(maxHeight: .infinity, alignment: .bottom)
                                .padding(.bottom, showControls ? 300 : 90)
                                .allowsHitTesting(false)
                        }
                        if !controlsGone { controls(now: context.date).opacity(showControls ? 1 : 0) }
                    }
                }
            }
            if let error = model.error {
                VStack(spacing: 30) {
                    Text(error).font(.system(size: 34, weight: .semibold)).multilineTextAlignment(.center)
                    Button("Back", action: close).buttonStyle(TVButtonStyle())
                }
                .padding(60).background(Theme.card, in: .rect(cornerRadius: 28))
            }
        }
        .foregroundStyle(Theme.light)
        .defaultFocus($focus, .surface)
        .onPlayPauseCommand(perform: poke)
        .onExitCommand(perform: back)
        .task(id: lastActivity) {
            try? await Task.sleep(for: .seconds(ControlsFade.remoteDelay))
            guard !Task.isCancelled, popup == nil, output.player.timeControlStatus == .playing else { return }
            if !reduceMotion { withAnimation(ControlsFade.animation) { showControls = false } }
            try? await Task.sleep(for: .seconds(ControlsFade.fade))
            if !Task.isCancelled { hideControls() }
        }
    }

    private func controls(now: Date) -> some View {
        let station = tuner.station
        let progress = station.onAir.now.map { StationText.progress($0, at: now) }
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
                        case .quality: QualityMenu(model: model, focus: $focus) { closeMenu(.pill) }
                        case .subtitles: SubtitlesMenu(model: model, focus: $focus) { closeMenu(.subtitles) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.bottom, 24)
                    .focusSection()
                }
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(station.name).font(.system(size: 52, weight: .bold)).lineLimit(1)
                        if let line = StationText.lines(station.onAir, kind: station.kind).first {
                            Text(line).font(.system(size: 30))
                                .foregroundStyle(Theme.synopsis).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 40)
                    buttons
                }
                ProgressBar(value: progress?.fraction ?? 0, height: 8).padding(.top, 26)
                    .accessibilityLabel("\(Int((progress?.fraction ?? 0) * 100)) percent played")
                HStack {
                    Text(Format.clock(seconds: progress?.elapsed ?? 0)).monospacedDigit()
                    Spacer()
                    Text("-" + Format.clock(seconds: progress?.remaining ?? 0)).monospacedDigit()
                }
                .font(.system(size: 30))
                .padding(.top, 24)
            }
            .padding(Theme.safeArea)
        }
    }

    private var buttons: some View {
        HStack(spacing: 20) {
            Button {
                open(.quality)
            } label: {
                QualityPill(model: model)
            }
            .focused($focus, equals: .pill)
            .accessibilityLabel("Playback quality: \(model.pill)")
            if !model.live {
                Button {
                    open(.subtitles)
                } label: {
                    Label("Subtitles", systemImage: "captions.bubble")
                }
                .focused($focus, equals: .subtitles)
            }
        }
        .buttonStyle(PlayerButtonStyle())
        .focusSection()
        .onMoveCommand { if $0 == .down, popup == nil { focus = .surface } }
    }

    private func move(_ direction: MoveCommandDirection) {
        if direction == .up, showControls, !tuner.offAir {
            focus = .pill
        } else {
            poke()
        }
    }

    private func back() {
        if let open = popup {
            closeMenu(open == .quality ? .pill : .subtitles)
        } else if focus != .surface {
            focus = .surface
            poke()
        } else {
            close()
        }
    }

    private func open(_ menu: PlayerSurface.Popup) {
        popup = menu
        poke()
        // Focus moves once the menu's rows exist.
        Task { focus = .option(menu.selected(in: model)) }
    }

    private func closeMenu(_ button: Focus) {
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
}
