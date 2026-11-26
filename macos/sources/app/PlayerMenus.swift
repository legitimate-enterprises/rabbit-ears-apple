import AVFoundation
import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// The app's own volume, kept on this Mac, for the video players and the music player alike.
enum Volume {
    static let key = "volume"
    static let initial = 0.7
    static var stored: Float { Float(UserDefaults.standard.object(forKey: key) as? Double ?? initial) }
}

struct VolumeSlider: View {
    let player: AVPlayer
    @AppStorage(Volume.key) private var volume = Volume.initial

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary).accessibilityHidden(true)
            Slider(value: $volume, in: 0...1).frame(width: 90).controlSize(.small).accessibilityLabel("Volume")
        }
        .onChange(of: volume, initial: true) { player.volume = Float(volume) }
    }
}

struct QualityMenu: View {
    let model: PlayerModel

    var body: some View {
        Menu {
            Section(model.stream?.away == true ? "Away from home" : "Playing on this Mac") {
                ForEach(model.qualityOptions) { option in
                    Button {
                        Task { await model.selectQuality(option) }
                    } label: {
                        Label(
                            "\(option.name)  \(option.detail)  \(option.trailingLabel)",
                            systemImage: option.selected ? "checkmark" : "")
                    }
                    .disabled(option.blocked)
                    if option.choice == .auto { Divider() }
                }
            }
        } label: {
            HStack(spacing: 6) {
                if model.adjusting { Text("Adjusting…") } else { Text(model.pill) }
                Image(systemName: "chevron.up")
            }
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14).frame(height: 36)
            .background(.white.opacity(0.12), in: .capsule)
        }
        .menuStyle(.button).buttonStyle(.plain).fixedSize()
        .foregroundStyle(model.stream?.entry.verdict == .directPlay ? Theme.green : Color(hex: 0xF2F2F7))
        .accessibilityLabel("Playback quality: \(model.pill)")
    }
}

struct SubtitlesMenu: View {
    let model: PlayerModel
    let offersTracks: Bool

    var body: some View {
        let tracks = offersTracks ? subtitleTracks : []
        return Menu {
            choice(.off, "Off")
            choice(.forcedOnly, "Only for other languages")
            ForEach(tracks, id: \.id) { track in choice(.track(track.id), track.label) }
        } label: {
            Image(systemName: "captions.bubble").font(.system(size: 18)).frame(width: 44, height: 44)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Subtitles")
    }

    private var subtitleTracks: [(id: Int64, label: String)] {
        model.subtitleTracks.map {
            ($0.id, Format.language($0.language) + ($0.title.map { " \($0)" } ?? ""))
        }
    }

    private func choice(_ value: PlayerModel.SubtitleChoice, _ label: String) -> some View {
        Button {
            Task { await model.selectSubtitles(value) }
        } label: {
            Label(label, systemImage: model.subtitleChoice == value ? "checkmark" : "")
        }
    }
}
