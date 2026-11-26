import AVFoundation
import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

struct SubtitleOption {
    let value: PlayerModel.SubtitleChoice
    let title: String
    var detail: String?

    init(_ track: Track) {
        value = .track(track.id)
        title = Format.language(track.language) + (track.title.map { " \($0)" } ?? "")
        detail = track.title?.localizedCaseInsensitiveContains("SDH") == true ? "Includes sound cues" : nil
    }

    init(value: PlayerModel.SubtitleChoice, title: String, detail: String? = nil) {
        self.value = value
        self.title = title
        self.detail = detail
    }

    @MainActor
    static func choices(_ model: PlayerModel) -> [SubtitleOption] {
        [
            SubtitleOption(value: .off, title: "Off"),
            SubtitleOption(
                value: .forcedOnly, title: "Only for non-English",
                detail: "Shows the forced track when another language is spoken"),
        ] + model.subtitleTracks.filter { !$0.isForced }.map(SubtitleOption.init)
    }
}

extension PlayerSurface.Popup {
    @MainActor
    func selected(in model: PlayerModel) -> Int {
        switch self {
        case .quality: model.qualityOptions.firstIndex(where: \.selected) ?? 0
        case .subtitles: SubtitleOption.choices(model).firstIndex { $0.value == model.subtitleChoice } ?? 0
        }
    }
}

/// `[4K] [HDR] Direct play 38 Mb/s`, or `[1080p] Auto 8 Mb/s` while Auto picks the rung.
struct QualityPill: View {
    let model: PlayerModel

    var body: some View {
        HStack(spacing: 12) {
            if model.adjusting {
                Text("Adjusting…")
            } else if let stream = model.stream {
                let auto = stream.auto == true
                let rung =
                    model.rungInUse ?? RungInUse(height: stream.negotiated.height, bitrate: stream.negotiated.bitrate)
                let negotiated = stream.negotiated
                if auto {
                    Tag(text: Format.resolution(height: rung.height))
                } else {
                    Tag(text: Format.resolution(width: negotiated.width, height: negotiated.height))
                    if negotiated.hdrFormat != nil { Tag(text: "HDR") }
                }
                Text(auto ? "Auto" : Format.verdict(negotiated.verdict))
                Text(Format.bitrate(auto ? rung.bitrate : negotiated.bitrate)).fontWeight(.regular).opacity(0.65)
            }
        }
    }
}

struct QualityMenu: View {
    let model: PlayerModel
    var focus: FocusState<PlayerSurface.Focus?>.Binding
    let done: () -> Void

    var body: some View {
        PlayerMenu(heading: model.stream?.away == true ? "Away from home" : nil, width: 710) {
            ForEach(Array(model.qualityOptions.enumerated()), id: \.element.id) { index, option in
                MenuRow(
                    title: option.name, detail: option.detail, trailing: option.trailingLabel,
                    trailingColor: option.blocked
                        ? Theme.secondary : option.verdict == .directPlay ? Theme.green : Theme.amber,
                    selected: option.selected
                ) {
                    done()
                    Task { await model.selectQuality(option) }
                }
                .focused(focus, equals: .option(index))
                .disabled(option.blocked)
                .opacity(option.blocked ? 0.45 : 1)
            }
        }
    }
}

struct SubtitlesMenu: View {
    let model: PlayerModel
    var focus: FocusState<PlayerSurface.Focus?>.Binding
    let done: () -> Void

    var body: some View {
        PlayerMenu(heading: nil, width: 710) {
            ForEach(Array(SubtitleOption.choices(model).enumerated()), id: \.offset) { index, choice in
                MenuRow(title: choice.title, detail: choice.detail, selected: model.subtitleChoice == choice.value) {
                    done()
                    Task { await model.selectSubtitles(choice.value) }
                }
                .focused(focus, equals: .option(index))
            }
        }
    }
}

struct EditionMenu: View {
    @Bindable var cuts: EditionChoice

    var body: some View {
        if cuts.offered {
            Menu {
                Picker("Edition", selection: $cuts.editionId) {
                    ForEach(cuts.editions, id: \.id) { Text(Editions.label($0)).tag(Optional($0.id)) }
                }
            } label: {
                HStack(spacing: 16) {
                    Text(cuts.chosen?.name ?? "")
                    Image(systemName: "chevron.down").font(.system(size: 20, weight: .bold))
                }
            }
            .buttonStyle(TVButtonStyle())
            .accessibilityLabel("Edition")
        }
    }
}

struct ScrubTrack: View {
    let position: Double
    let duration: Double
    let scrubbing: Bool
    let preview: URL?

    private let card = 400.0

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fraction = duration > 0 ? min(1, max(0, position / duration)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3)).frame(height: 12)
                Capsule().fill(Theme.amber).frame(width: width * fraction, height: 12)
                Capsule().fill(.white).frame(width: 6, height: 44).offset(x: width * fraction - 3)
            }
            .frame(maxHeight: .infinity)
            .overlay(alignment: .bottomLeading) {
                if scrubbing, let preview {
                    let center = Scrub.cardCenter(atX: width * fraction, width: width, card: card)
                    PreviewCard(url: preview, seconds: position, width: card)
                        .offset(x: center - card / 2, y: -40)
                }
            }
        }
        .frame(height: 44)
        .accessibilityElement()
        .accessibilityLabel("Seek")
        .accessibilityValue(Format.clock(seconds: position))
    }
}

struct PreviewCard: View {
    let url: URL
    let seconds: Double
    let width: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                LinearGradient(
                    colors: [Color(hex: 0x2E6B8A), Color(hex: 0x17304A)], startPoint: .topLeading,
                    endPoint: .bottomTrailing)
            }
            .frame(width: width, height: width * 9 / 16).clipped()
            Text(Format.clock(seconds: seconds)).font(.system(size: 28, weight: .bold)).monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(width: width)
        .background(Theme.card)
        .clipShape(.rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.18)))
        .shadow(color: .black.opacity(0.6), radius: 30, y: 16)
    }
}

struct PlayerMenu<Content: View>: View {
    let heading: String?
    let width: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let heading {
                Text(heading).font(.system(size: 26)).foregroundStyle(Theme.secondary)
                    .padding(EdgeInsets(top: 14, leading: 36, bottom: 8, trailing: 36))
            }
            content
        }
        .padding(.vertical, 12)
        .frame(width: width, alignment: .leading)
        .background(Theme.card, in: .rect(cornerRadius: 28))
        .shadow(color: .black.opacity(0.6), radius: 40, y: 20)
    }
}

struct MenuRow: View {
    let title: String
    var detail: String?
    var trailing: String?
    var trailingColor = Theme.amber
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 20) {
                Image(systemName: "checkmark").font(.system(size: 26, weight: .bold)).frame(width: 30)
                    .opacity(selected ? 1 : 0)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 30, weight: .bold))
                    if let detail { Text(detail).font(.system(size: 26)).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 20)
                if let trailing {
                    Text(trailing).font(.system(size: 28, weight: .bold)).foregroundStyle(trailingColor)
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(RowButtonStyle(radius: 18, scale: 1.02))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct PlayerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 28, weight: .bold))
            .labelStyle(TVLabelStyle())
            .padding(.horizontal, 24)
            .frame(height: 64)
            .background(Theme.control, in: .capsule)
            .modifier(FocusLift(scale: 1.05))
    }
}

struct BareButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

struct VideoLayer: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) { view.playerLayer.player = player }
}

final class PlayerLayerView: UIView {
    let playerLayer = AVPlayerLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }
}
