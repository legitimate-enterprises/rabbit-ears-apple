import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// The raised card the quality and subtitles menus open in above their buttons.
struct PopupMenu<Content: View>: View {
    let heading: String?
    let width: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let heading {
                Text(heading).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    .padding(EdgeInsets(top: 6, leading: 10, bottom: 8, trailing: 10))
            }
            content
        }
        .padding(8)
        .frame(width: width, alignment: .leading)
        .background(Theme.raised, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.6), radius: 20, y: 12)
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
            HStack(spacing: 10) {
                Image(systemName: "checkmark").font(.system(size: 13, weight: .heavy)).foregroundStyle(Theme.amber)
                    .frame(width: 16).opacity(selected ? 1 : 0)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(Theme.synopsis) }
                }
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing).font(.system(size: 12, weight: .semibold)).foregroundStyle(trailingColor)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(minHeight: 40)
            .background(selected ? .white.opacity(0.08) : .clear, in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.primary)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct QualityPill: View {
    let model: PlayerModel
    let open: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(model.adjusting ? "Adjusting…" : model.pill).font(.system(size: 13, weight: .semibold))
                Image(systemName: "chevron.up").font(.system(size: 11, weight: .bold))
            }
            .padding(.horizontal, 12).frame(height: 36)
            .background(.white.opacity(open ? 0.22 : 0.12), in: .capsule)
        }
        .buttonStyle(.plain)
        .foregroundStyle(model.stream?.entry.verdict == .directPlay ? Theme.green : .white)
        .accessibilityLabel("Playback quality: \(model.pill)")
    }
}

/// The quality choices the server offers for this stream; `close` runs on a pick.
struct QualityPopup: View {
    let model: PlayerModel
    let capabilities: SystemCapabilities
    let close: () -> Void

    var body: some View {
        PopupMenu(
            heading: QualityHeading.text(
                away: model.stream?.away == true, path: capabilities.facts().path, airPlay: capabilities.airPlayName),
            width: 340
        ) {
            ForEach(model.qualityOptions) { option in
                MenuRow(
                    title: option.name, detail: option.detail, trailing: option.trailingLabel,
                    trailingColor: option.blocked
                        ? Theme.secondary : option.verdict == .directPlay ? Theme.green : Theme.amber,
                    selected: option.selected
                ) {
                    close()
                    Task { await model.selectQuality(option) }
                }
                .disabled(option.blocked)
                .opacity(option.blocked ? 0.45 : 1)
                if option.choice == .auto { Divider().overlay(.white.opacity(0.1)).padding(.horizontal, 6) }
            }
        }
    }
}

/// Off, forced only, and the file's subtitle tracks when `offersTracks`.
struct SubtitlesPopup: View {
    let model: PlayerModel
    let offersTracks: Bool
    let close: () -> Void

    var body: some View {
        PopupMenu(heading: nil, width: 300) {
            choice(.off, "Off")
            choice(
                .forcedOnly, "Only for non-English", detail: "Shows the forced track when another language is spoken")
            ForEach(offersTracks ? tracks : [], id: \.id) { track in choice(.track(track.id), track.label) }
        }
    }

    private var tracks: [(id: UID, label: String)] {
        model.subtitleTracks.map {
            ($0.id, Format.language($0.language) + ($0.title.map { " \($0)" } ?? ""))
        }
    }

    private func choice(_ value: PlayerModel.SubtitleChoice, _ label: String, detail: String? = nil) -> some View {
        MenuRow(title: label, detail: detail, selected: model.subtitleChoice == value) {
            close()
            Task { await model.selectSubtitles(value) }
        }
    }
}

/// A movie's edition choice on details; nothing for a title of one.
struct EditionPicker: View {
    @Bindable var cuts: EditionChoice

    var body: some View {
        if cuts.offered {
            KeyValue(key: "Edition") {
                Picker("Edition", selection: $cuts.editionId) {
                    ForEach(cuts.editions, id: \.id) { Text(Editions.label($0)).tag(Optional($0.id)) }
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
