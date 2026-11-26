import CarPlay
import RabbitEarsKit

/// What a list template reads from, kept in its userInfo so it can be read again.
enum CarPlaySource: Equatable {
    case recent, albums, artists, playlists
    case destination(CarPlayDestination)
}

/// Turns CarPlayLibrary's lists into templates, with artwork and the playing indicator.
@MainActor
final class CarPlayTemplates {
    private struct Marked {
        weak var item: CPListItem?
        let marker: CarPlayRow.Marker
    }

    private var marked: [Marked] = []
    weak var car: CarPlayController?

    func tabBar() -> CPTabBarTemplate {
        let sources: [CarPlaySource] = [.recent, .albums, .artists, .playlists]
        let tabs = [
            ("Recent", "clock"), ("Albums", "square.stack"), ("Artists", "person"), ("Playlists", "music.note.list"),
        ]
        return CPTabBarTemplate(
            templates: zip(sources, tabs).map { source, tab in
                let template = list(tab.0, source)
                template.tabTitle = tab.0
                template.tabImage = UIImage(systemName: tab.1)
                return template
            })
    }

    /// A state with no music: the server's name over a message, or a spinner while it loads.
    func message(_ message: CarPlayMessage?, title: String) -> CPListTemplate {
        let template = CPListTemplate(title: title, sections: [])
        template.showsSpinnerWhileEmpty = message == nil
        template.emptyViewTitleVariants = message.map { [$0.title] } ?? []
        template.emptyViewSubtitleVariants = message?.detail.map { [$0] } ?? []
        return template
    }

    /// A list pushed from a row, shown with a spinner until it loads.
    func pushed(_ destination: CarPlayDestination, title: String) -> CPListTemplate {
        let title =
            switch destination {
            case .album: "Album"
            case .artist: "Artist"
            case .playlist: title
            case .letter(_, let letter): letter
            }
        return list(title, .destination(destination))
    }

    func source(of template: CPTemplate) -> CarPlaySource? { template.userInfo as? CarPlaySource }

    func fill(_ template: CPListTemplate, _ list: CarPlayList) {
        template.showsSpinnerWhileEmpty = false
        template.emptyViewTitleVariants = list.empty.map { [$0.title] } ?? []
        template.emptyViewSubtitleVariants = list.empty?.detail.map { [$0] } ?? []
        template.updateSections(
            list.sections.map { section in
                CPListSection(
                    items: section.rows.map { item($0, in: list) },
                    header: section.header, sectionIndexTitle: section.index)
            })
        guard let header = list.header else { return }
        template.listHeader = details(header, placeholder(header.art))
        guard let art = header.art else { return }
        Task {
            guard let image = await image(art) else { return }
            template.listHeader = details(header, image)
        }
    }

    func markPlaying(_ song: MusicSong?) {
        marked.removeAll { $0.item == nil }
        for entry in marked { entry.item?.isPlaying = entry.marker.matches(song) }
    }

    private func list(_ title: String, _ source: CarPlaySource) -> CPListTemplate {
        let template = CPListTemplate(title: title, sections: [])
        template.showsSpinnerWhileEmpty = true
        template.userInfo = source
        return template
    }

    private func item(_ row: CarPlayRow, in list: CarPlayList) -> CPListItem {
        let item = CPListItem(
            text: row.text, detailText: row.detail, image: row.art.map(placeholder), accessoryImage: nil,
            accessoryType: row.opens ? .disclosureIndicator : .none)
        item.handler = { [weak self] _, completion in
            Task { @MainActor in
                await self?.car?.perform(row.action, in: list, title: row.text)
                completion()
            }
        }
        if let marker = row.marker {
            if case .song = marker {
                item.playingIndicatorLocation = .leading
            } else {
                item.playingIndicatorLocation = .trailing
            }
            marked.append(Marked(item: item, marker: marker))
        }
        if let art = row.art {
            Task { [weak item] in
                guard let image = await image(art) else { return }
                item?.setImage(image)
            }
        }
        return item
    }

    private func details(_ header: CarPlayHeader, _ art: UIImage) -> CPListTemplateDetailsHeader {
        let play = CPButton(image: UIImage(systemName: "play.fill") ?? UIImage()) { [weak self] _ in
            Task { await self?.car?.play(header.play, shuffled: false) }
        }
        play.title = "Play"
        let shuffle = CPButton(image: UIImage(systemName: "shuffle") ?? UIImage()) { [weak self] _ in
            Task { await self?.car?.play(header.play, shuffled: true) }
        }
        shuffle.title = "Shuffle"
        return CPListTemplateDetailsHeader(
            thumbnail: CPThumbnailImage(image: art), title: header.title, subtitle: header.subtitle,
            actionButtons: [play, shuffle])
    }

    /// The album's or artist's poster at the size the car draws it; artists are round.
    private func image(_ art: CarPlayRow.Art) async -> UIImage? {
        guard let car else { return nil }
        let scale = max(1, car.interface.carTraitCollection.displayScale)
        let size = CPListItem.maximumImageSize
        let pixels = Int(max(size.width, size.height) * scale)
        let artwork = car.context.model.artwork
        let (bitmap, round): (CGImage?, Bool) =
            switch art {
            case .square(let id): (await artwork?.image(id, .poster, maxPixel: pixels), false)
            case .round(let id): (await artwork?.image(id, .poster, maxPixel: pixels), true)
            case .custom(let url): (await artwork?.image(url: url, maxPixel: pixels), false)
            }
        guard let bitmap else { return nil }
        return draw(size, round: round) { UIImage(cgImage: bitmap).draw(in: $0) }
    }

    /// A grey stand-in until the artwork arrives, in the artwork's shape.
    private func placeholder(_ art: CarPlayRow.Art?) -> UIImage {
        let round = if case .round = art { true } else { false }
        return draw(CPListItem.maximumImageSize, round: round) { rect in
            UIColor(white: 0.25, alpha: 1).setFill()
            UIRectFill(rect)
        }
    }

    private func draw(_ size: CGSize, round: Bool, _ content: (CGRect) -> Void) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { _ in
            let rect = CGRect(origin: .zero, size: size)
            (round ? UIBezierPath(ovalIn: rect) : UIBezierPath(roundedRect: rect, cornerRadius: size.width / 8))
                .addClip()
            content(rect)
        }
    }
}
