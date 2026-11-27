import AVKit
import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

extension Browser {
    /// Tunes in: a music station in the music player, shown on Now playing; any other in the station player.
    func tune(_ station: Station, music: RabbitEarsKit.MusicPlayer, app: AppModel) {
        guard station.kind == .music else {
            tuning = station
            return
        }
        guard let client = app.client, let replica = app.sync?.replica, let profile = app.activeProfile else { return }
        Task {
            await music.tune(StationTuner(client: client, replica: replica, profileId: profile.id, station: station))
        }
        showingNowPlaying = true
    }
}

/// The full-screen player tuned in to a movies or tv station. Nothing
/// pauses, seeks or skips; the station's clock decides what plays.
struct StationPlayerScreen: View {
    let station: Station
    let client: Client
    /// Nil once signed out, when nothing plays.
    let replica: Replica?
    let endpoint: ServerEndpoint
    let profileId: UID
    let close: () -> Void
    @State private var model: PlayerModel?
    @State private var output: AVPlayerOutput?
    @State private var capabilities: SystemCapabilities?
    @State private var tuner: StationTuner?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let model, let output, let capabilities, let tuner {
                StationSurface(model: model, output: output, capabilities: capabilities, tuner: tuner, close: close)
            }
        }
        .task {
            guard let replica else { return }
            // Plays with the ringer off and keeps playing in picture in picture and over AirPlay.
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            let output = AVPlayerOutput()
            let capabilities = AppContext.shared.capabilities
            let model = PlayerModel(
                client: client, endpoint: endpoint, profileId: profileId, item: nil, output: output,
                capabilities: capabilities, device: "iPhone")
            let tuner = StationTuner(client: client, replica: replica, profileId: profileId, station: station)
            self.output = output
            self.capabilities = capabilities
            self.model = model
            self.tuner = tuner
            await model.tune(tuner, on: output)
        }
        .onDisappear { Task { await model?.stop() } }
        .onChange(of: scenePhase) { _, phase in if phase == .active { tuner?.resume() } }
    }
}

struct StationSurface: View {
    enum Popup { case quality, subtitles }

    let model: PlayerModel
    let output: AVPlayerOutput
    let capabilities: SystemCapabilities
    let tuner: StationTuner
    let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showControls = true
    @State private var controlsGone = false
    @State private var lastActivity = Date()
    @State private var popup: Popup?
    @State private var pip: AVPictureInPictureController?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // Kept while off the air, so picture in picture survives the gap between programs.
            VideoSurface(player: output.player, pip: $pip).ignoresSafeArea()
            if tuner.offAir { identity }
            Color.clear.contentShape(.rect).ignoresSafeArea()
                .onTapGesture { showControls ? hide() : poke() }
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                ZStack {
                    let seconds = output.player.currentTime().seconds
                    if !tuner.offAir, let cue = model.cue(at: seconds.isFinite ? seconds : 0) {
                        Text(cue).font(.system(size: 18, weight: .semibold)).multilineTextAlignment(.center)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(.black.opacity(0.6), in: .rect(cornerRadius: 4))
                            .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, showControls ? 110 : 30)
                            .allowsHitTesting(false)
                    }
                    if !controlsGone || tuner.offAir {
                        controls(now: context.date).opacity(showControls || tuner.offAir ? 1 : 0)
                    }
                }
            }
            if let error = model.error {
                VStack(spacing: 12) {
                    Text(error).font(.system(size: 15, weight: .semibold)).multilineTextAlignment(.center)
                    Button("Back", action: leave).buttonStyle(SecondaryButtonStyle())
                }
                .padding(24).background(Theme.card, in: .rect(cornerRadius: 14)).padding(24)
            }
        }
        .foregroundStyle(Theme.primary)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task(id: lastActivity) {
            guard await ControlsFade.idle(output.player, for: ControlsFade.delay), popup == nil else { return }
            if !reduceMotion { withAnimation(ControlsFade.animation) { showControls = false } }
            try? await Task.sleep(for: .seconds(ControlsFade.fade))
            if !Task.isCancelled { (showControls, controlsGone) = (false, true) }
        }
    }

    private var identity: some View {
        let station = tuner.station
        return ZStack {
            Theme.ground.ignoresSafeArea()
            VStack(spacing: 14) {
                if station.imageUrl != nil {
                    StationIdentity(
                        id: station.id, name: station.name, aspect: 1, radius: 10, imageUrl: station.imageUrl
                    )
                    .frame(width: 120)
                } else {
                    StationGlyph(size: 48)
                }
                Text(station.name).font(.system(size: 30, weight: .bold)).multilineTextAlignment(.center)
                Text(StationText.waiting(station.onAir, kind: station.kind)).font(.system(size: 14))
                    .foregroundStyle(Theme.synopsis)
            }
            .padding(24)
        }
    }

    private func controls(now: Date) -> some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.6), location: 0), .init(color: .clear, location: 0.22),
                    .init(color: .clear, location: 0.65), .init(color: .black.opacity(0.75), location: 1),
                ], startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .opacity(tuner.offAir ? 0 : 1)
            VStack {
                header
                Spacer()
                if !tuner.offAir { footer(now: now) }
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
                Text(tuner.station.name).font(.system(size: 18, weight: .bold)).lineLimit(1)
                if !tuner.offAir, let line = StationText.lines(tuner.station.onAir, kind: tuner.station.kind).first {
                    Text(line).font(.system(size: 13))
                        .foregroundStyle(Theme.synopsis).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if pip != nil {
                PlayerButton(icon: "pip.enter", label: "Picture in picture") { pip?.startPictureInPicture() }
            }
            RoutePicker().frame(width: 44, height: 44).accessibilityLabel("AirPlay")
        }
    }

    private func footer(now: Date) -> some View {
        let station = tuner.station
        let progress = station.onAir.now.map { StationText.progress($0, at: now) }
        return VStack(spacing: 10) {
            HStack(spacing: 12) {
                Text(Format.clock(seconds: progress?.elapsed ?? 0)).monospacedDigit()
                ProgressBar(value: progress?.fraction ?? 0, height: 4)
                Text("-" + Format.clock(seconds: progress?.remaining ?? 0)).monospacedDigit()
            }
            .font(.system(size: 13))
            .foregroundStyle(Color(hex: 0xE5E5EA))
            ZStack {
                HStack(spacing: 4) {
                    Spacer()
                    if !model.live {
                        PlayerButton(icon: "captions.bubble", label: "Subtitles") { toggle(.subtitles) }
                            .overlay(alignment: .bottomTrailing) {
                                if popup == .subtitles {
                                    SubtitlesPopup(model: model, offersTracks: true) { popup = nil }
                                        .offset(y: -52).fixedSize()
                                }
                            }
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

    private func leave() {
        Task { await model.stop() }
        close()
    }
}
