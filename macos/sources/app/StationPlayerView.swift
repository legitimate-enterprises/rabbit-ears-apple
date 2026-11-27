import AVKit
import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

extension Browser {
    /// Tunes in: a music station in the music player, shown on Now playing; any other in the player.
    func tune(_ station: Station, music: RabbitEarsKit.MusicPlayer?, app: AppModel) {
        guard station.kind == .music else {
            tuning = station
            return
        }
        guard let music, let client = app.client, let replica = app.sync?.replica, let profile = app.activeProfile
        else { return }
        Task {
            await music.tune(StationTuner(client: client, replica: replica, profileId: profile.id, station: station))
        }
        if path.last != .nowPlaying { path.append(.nowPlaying) }
    }
}

/// The full-window player tuned in to a movies or tv station. Nothing
/// pauses, seeks or skips; the station's clock decides what plays.
struct StationPlayerScreen: View {
    let station: Station
    let client: Client
    let replica: Replica
    let endpoint: ServerEndpoint
    let profileId: UID
    let capabilities: SystemCapabilities
    let close: () -> Void
    @State private var model: PlayerModel?
    @State private var output: AVPlayerOutput?
    @State private var tuner: StationTuner?

    var body: some View {
        ZStack {
            Color.black
            if let model, let output, let tuner {
                StationSurface(model: model, output: output, tuner: tuner, close: close)
            }
        }
        .ignoresSafeArea()
        .task {
            let output = AVPlayerOutput()
            let model = PlayerModel(
                client: client, endpoint: endpoint, profileId: profileId, item: nil, output: output,
                capabilities: capabilities)
            let tuner = StationTuner(client: client, replica: replica, profileId: profileId, station: station)
            // The stream ending is the program ending: ask for what is on next.
            output.onEnd = { [weak model, weak tuner] in
                guard let model, let tuner else { return }
                Task { await model.programEnded(tuner) }
            }
            self.output = output
            self.model = model
            self.tuner = tuner
            await model.tune(tuner)
        }
        .onDisappear { Task { await model?.stop() } }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            tuner?.resume()
        }
    }
}

struct StationSurface: View {
    let model: PlayerModel
    let output: AVPlayerOutput
    let tuner: StationTuner
    let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showControls = true
    @State private var controlsGone = false
    @State private var lastActivity = Date()
    @State private var muted = false
    @AppStorage(Volume.key) private var volume = Volume.initial
    @FocusState private var focused: Bool
    @State private var pip: AVPictureInPictureController?

    var body: some View {
        let station = tuner.station
        ZStack {
            Color.black
            // Kept while off the air, so picture in picture survives the gap between programs.
            VideoSurface(player: output.player, pip: $pip)
            if tuner.offAir {
                Theme.ground
                VStack(spacing: 18) {
                    if station.imageUrl != nil {
                        StationIdentity(
                            id: station.id, name: station.name, aspect: 1, radius: 12, imageUrl: station.imageUrl
                        )
                        .frame(width: 220)
                    } else {
                        StationGlyph(size: 76)
                    }
                    Text(station.name).font(.system(size: 44, weight: .bold))
                    Text(StationText.waiting(station.onAir, kind: station.kind)).font(.system(size: 18))
                        .foregroundStyle(Theme.synopsis)
                }
            }
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                ZStack {
                    let seconds = output.player.currentTime().seconds
                    if let cue = model.cue(at: seconds.isFinite ? seconds : 0) {
                        Text(cue).font(.system(size: 22, weight: .semibold)).multilineTextAlignment(.center)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(.black.opacity(0.6), in: .rect(cornerRadius: 4))
                            .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, showControls ? 120 : 40)
                    }
                    if !controlsGone || tuner.offAir {
                        controls(now: context.date).opacity(showControls || tuner.offAir ? 1 : 0)
                    }
                }
            }
            if let error = model.error {
                VStack(spacing: 12) {
                    Text(error).font(.system(size: 15, weight: .semibold))
                    Button("Back", action: leave).buttonStyle(SecondaryButtonStyle())
                }
                .padding(24).background(Theme.card, in: .rect(cornerRadius: 14))
            }
        }
        .foregroundStyle(Color(hex: 0xF2F2F7))
        .ignoresSafeArea()
        .onContinuousHover { _ in poke() }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(action: key)
        .onAppear { focused = true }
        .task(id: lastActivity) {
            try? await Task.sleep(for: .seconds(ControlsFade.delay))
            guard !Task.isCancelled, output.player.timeControlStatus == .playing else { return }
            if !reduceMotion { withAnimation(ControlsFade.animation) { showControls = false } }
            try? await Task.sleep(for: .seconds(ControlsFade.fade))
            if !Task.isCancelled { (showControls, controlsGone) = (false, true) }
        }
    }

    private func controls(now: Date) -> some View {
        VStack {
            header
            Spacer()
            if !tuner.offAir { footer(now: now) }
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
                Text(tuner.station.name).font(.system(size: 18, weight: .bold))
                if !tuner.offAir, let line = StationText.lines(tuner.station.onAir, kind: tuner.station.kind).first {
                    Text(line).font(.system(size: 13))
                        .foregroundStyle(Theme.synopsis)
                }
            }
            Spacer()
            if pip != nil {
                PlayerButton(icon: "pip.enter", label: "Picture in picture") { pip?.startPictureInPicture() }
            }
            RoutePicker(player: output.player).frame(width: 44, height: 44).accessibilityLabel("AirPlay")
        }
        // Clears the title bar's window buttons, which stay over the video.
        .padding(EdgeInsets(top: 40, leading: 20, bottom: 0, trailing: 20))
    }

    private func footer(now: Date) -> some View {
        let station = tuner.station
        let progress = station.onAir.now.map { StationText.progress($0, at: now) }
        return VStack(spacing: 10) {
            HStack(spacing: 12) {
                Text(Format.clock(seconds: progress?.elapsed ?? 0)).monospacedDigit()
                ProgressBar(value: progress?.fraction ?? 0, height: 4)
                    .accessibilityLabel("\(Int((progress?.fraction ?? 0) * 100)) percent played")
                Text("-" + Format.clock(seconds: progress?.remaining ?? 0)).monospacedDigit()
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
                    if !model.live { SubtitlesMenu(model: model, offersTracks: true) }
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

    /// Leaving ends the session and stops asking the station.
    private func leave() {
        Task { await model.stop() }
        close()
    }

    private func key(_ press: KeyPress) -> KeyPress.Result {
        poke()
        guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
        switch press.key {
        case .upArrow: volume = min(1, volume + 0.1)
        case .downArrow: volume = max(0, volume - 0.1)
        case .escape:
            if NSApp.keyWindow?.styleMask.contains(.fullScreen) == true {
                NSApp.keyWindow?.toggleFullScreen(nil)
            } else {
                leave()
            }
        default:
            switch press.characters.lowercased() {
            case "m":
                muted.toggle()
                output.player.isMuted = muted
            case "f": NSApp.keyWindow?.toggleFullScreen(nil)
            case "c" where !model.live: Task { await model.nextSubtitles() }
            default: return .ignored
            }
        }
        return .handled
    }
}
