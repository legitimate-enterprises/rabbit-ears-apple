import Foundation
import Observation
import RabbitEarsAPI

public typealias Edition = Components.Schemas.Edition

/// The cut a title plays. A saved position belongs to one edition and the
/// server resumes only that one; the server, not the viewer, picks the copy.
public enum Editions {
    /// The edition the position to resume belongs to, else the default.
    public static func preselected(_ editions: [Edition], watch: WatchState?) -> Edition? {
        let resumable = watch.flatMap { $0.positionMs == 0 ? nil : $0.editionId }
        return editions.first { $0.id == resumable } ?? editions.first(where: \.isDefault) ?? editions.first
    }

    /// Resume is offered only with the position's own edition chosen; with
    /// editions not yet read, any position counts.
    public static func resumes(_ edition: Edition?, watch: WatchState?) -> Bool {
        guard let watch, watch.positionMs > 0 else { return false }
        return edition.map { watch.editionId == $0.id } ?? true
    }

    /// `Extended · 3h 48m · 4K, 1080p`.
    public static func label(_ edition: Edition) -> String {
        var qualities: [String] = []
        for quality in edition.copies.compactMap(\.quality) where !qualities.contains(quality) {
            qualities.append(quality)
        }
        let runtime = edition.runtimeMs.map { Format.runtime(minutes: Int(($0 + 30_000) / 60_000)) }
        let parts: [String?] = [edition.name, runtime, qualities.isEmpty ? nil : qualities.joined(separator: ", ")]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    /// What play names: nothing for a title of one edition, and nothing in
    /// Watch together, which always plays the default.
    public static func sent(_ edition: Edition?, of editions: [Edition], together: Bool) -> Int64? {
        editions.count > 1 && !together ? edition?.id : nil
    }

    /// What a start names. `chosen` is `.none` where no edition was chosen,
    /// as from Home, which then resumes the position's edition outside Watch
    /// together; a choice made on details, `.some(nil)` for the default, stands.
    public static func started(_ chosen: Int64??, item: Item.ID, in catalog: Catalog, together: Bool) -> Int64? {
        chosen ?? (together ? nil : catalog.resumeEdition(item))
    }
}

/// A movie's or episode's details: its editions, the one chosen, and the
/// files they hold.
@MainActor
@Observable
public final class EditionChoice {
    public private(set) var editions: [Edition] = []
    public var editionId: Int64?
    private var files: [Components.Schemas.MediaFile] = []

    public init() {}

    public func load(_ itemId: Item.ID, from model: CatalogModel) async {
        async let read = model.editions(itemId)
        files = (try? await model.client.listMediaFiles(query: .init(itemId: itemId)).ok.body.json.items) ?? []
        editions = await read
        editionId = Editions.preselected(editions, watch: model.catalog.watch[itemId])?.id
    }

    public var chosen: Edition? { editions.first { $0.id == editionId } }
    public var offered: Bool { editions.count > 1 }

    /// The file whose tracks details shows: the chosen edition's first copy, else the first.
    public var file: Components.Schemas.MediaFile? {
        files.first { $0.id == chosen?.copies.first?.mediaFileId } ?? files.first
    }

    public func resumes(_ watch: WatchState?) -> Bool { Editions.resumes(chosen, watch: watch) }

    /// What Play hands the browser: `.none` while unread, so the start
    /// resumes the position's own edition.
    public func sent(together: Bool) -> Int64?? {
        editions.isEmpty ? Int64??.none : Editions.sent(chosen, of: editions, together: together)
    }
}

extension Catalog {
    /// The edition a Resume outside details plays, the one holding the position.
    public func resumeEdition(_ id: Item.ID) -> Int64? {
        isInProgress(id) ? watch[id]?.editionId : nil
    }
}

extension CatalogModel {
    /// A movie's or episode's editions, default first; empty when they cannot be read.
    public func editions(_ id: Item.ID) async -> [Edition] {
        (try? await client.getItem(path: .init(itemId: id)).ok.body.json.editions) ?? []
    }
}
