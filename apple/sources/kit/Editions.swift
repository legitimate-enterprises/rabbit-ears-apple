import Foundation
import GRDB
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
    public static func sent(_ edition: Edition?, of editions: [Edition], together: Bool) -> UID? {
        editions.count > 1 && !together ? edition?.id : nil
    }

    /// What a start names. `chosen` is `.none` where no edition was chosen,
    /// as from Home, which then resumes the position's edition outside Watch
    /// together; a choice made on details, `.some(nil)` for the default, stands.
    public static func started(_ chosen: UID??, item: Item.ID, in catalog: Catalog, together: Bool) -> UID? {
        chosen ?? (together ? nil : catalog.resumeEdition(item))
    }
}

/// A movie's or episode's details: its editions, the one chosen, and the
/// files they hold.
@MainActor
@Observable
public final class EditionChoice {
    public private(set) var editions: [Edition] = []
    public var editionId: UID?
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
    public func sent(together: Bool) -> UID?? {
        editions.isEmpty ? UID??.none : Editions.sent(chosen, of: editions, together: together)
    }
}

extension Catalog {
    /// The edition a Resume outside details plays, the one holding the position.
    public func resumeEdition(_ id: Item.ID) -> UID? {
        isInProgress(id) ? watch[id]?.editionId : nil
    }
}

extension CatalogModel {
    /// A movie's or episode's editions as getItem answers them, default
    /// first, then by name; empty when they cannot be read.
    public func editions(_ id: Item.ID) async -> [Edition] {
        (try? await replica.read { [profileId] db in
            guard
                try Bool.fetchOne(
                    db,
                    sql: "SELECT 1 FROM item WHERE id = ? AND kind IN ('movie', 'episode') AND id "
                        + ReplicaRows.seenBy,
                    arguments: [id, profileId]) == true
            else { return [] }
            return try Editions.of(id, db)
        }) ?? []
    }
}

extension Editions {
    /// One of edition.Repo's editions of an item, with or without files.
    struct Cut {
        let id: UID
        let tag: String
        let runtimeMs: Int64?
        let files: Int
        let onDisk: Int
        var name = ""
        var isDefault = false
    }

    /// Every edition of an item in id order, each runtime falling back to its
    /// largest file's, named and the default picked as edition.all does: an
    /// untagged cut is "Standard", or "N-minute cut" while the title has
    /// several with files; the default is the first untagged one with a file
    /// on disk, else the first with one, else the same among those with files.
    static func cuts(_ item: Item.ID, _ db: Database) throws -> [Cut] {
        var cuts = try Row.fetchAll(
            db,
            sql: """
                SELECT e.id, COALESCE(e.tag, '') AS tag,
                    COALESCE(e.runtime_ms, (SELECT f.duration_ms FROM edition_file ef
                        JOIN media_file f ON f.id = ef.media_file_id WHERE ef.edition_id = e.id
                        ORDER BY f.size_bytes DESC, f.id LIMIT 1)) AS runtime_ms,
                    (SELECT COUNT(*) FROM edition_file ef WHERE ef.edition_id = e.id) AS files,
                    (SELECT COUNT(*) FROM edition_file ef JOIN media_file f ON f.id = ef.media_file_id
                        WHERE ef.edition_id = e.id AND f.missing_at IS NULL) AS on_disk
                FROM edition e WHERE e.item_id = ? ORDER BY e.id
                """, arguments: [item]
        ).map {
            Cut(id: $0["id"], tag: $0["tag"], runtimeMs: $0["runtime_ms"], files: $0["files"], onDisk: $0["on_disk"])
        }
        let untagged = cuts.filter { $0.tag.isEmpty && $0.files > 0 }.count
        var chosen: Int?
        for needOnDisk in [true, false] where chosen == nil {
            for (index, cut) in cuts.enumerated()
            where cut.files > 0 && (!needOnDisk || cut.onDisk > 0)
                && (chosen.map { !cuts[$0].tag.isEmpty && cut.tag.isEmpty } ?? true)
            {
                chosen = index
            }
        }
        for index in cuts.indices {
            let cut = cuts[index]
            cuts[index].isDefault = index == chosen
            cuts[index].name = cut.tag.isEmpty ? "Standard" : cut.tag
            if cut.tag.isEmpty, untagged > 1, let runtime = cut.runtimeMs {
                cuts[index].name = "\((runtime + 30_000) / 60_000)-minute cut"
            }
        }
        return cuts
    }

    /// The name a row shows for one of the item's editions, as the server's
    /// editionName: nil while the item has fewer than two editions with files.
    static func name(of edition: UID, item: Item.ID, _ db: Database) throws -> String? {
        let cuts = try cuts(item, db)
        guard cuts.filter({ $0.files > 0 }).count > 1 else { return nil }
        return cuts.first { $0.id == edition }?.name
    }

    /// The item's editions that have files, default first then by name,
    /// each with its copies, the tallest picture first.
    static func of(_ item: Item.ID, _ db: Database) throws -> [Edition] {
        let kept = try cuts(item, db).filter { $0.files > 0 }.enumerated().sorted { lhs, rhs in
            if lhs.element.isDefault != rhs.element.isDefault { return lhs.element.isDefault }
            let (left, right) = (lhs.element.name.lowercased(), rhs.element.name.lowercased())
            return left != right ? left < right : lhs.offset < rhs.offset
        }
        return try kept.map(\.element).map { cut in
            Edition(
                id: cut.id, name: cut.name, isDefault: cut.isDefault, runtimeMs: cut.runtimeMs,
                copies: try copies(cut.id, db))
        }
    }

    private static func copies(_ edition: UID, _ db: Database) throws -> [Components.Schemas.EditionCopy] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT f.id, t.width, t.height, t.hdr_format, f.missing_at IS NOT NULL AS missing FROM edition_file ef
                    JOIN media_file f ON f.id = ef.media_file_id
                    LEFT JOIN track t ON t.id = (SELECT v.id FROM track v
                        WHERE v.media_file_id = f.id AND v.kind = 'video'
                        ORDER BY v.stream_index LIMIT 1)
                WHERE ef.edition_id = ?
                ORDER BY COALESCE(t.height, 0) DESC, COALESCE(t.width, 0) DESC, f.size_bytes DESC, f.id
                """, arguments: [edition]
        ).map { row in
            let (width, height): (Int?, Int?) = (row["width"], row["height"])
            return .init(
                mediaFileId: row["id"], quality: quality(width: width ?? 0, height: height ?? 0), width: width,
                height: height, hdrFormat: (row["hdr_format"] as String?).flatMap(Components.Schemas.HdrFormat.init),
                unavailable: row["missing"] ? true : nil)
        }
    }

    /// edition.Copy.Quality: nil for a file without video.
    static func quality(width: Int, height: Int) -> String? {
        switch true {
        case width >= 3200 || height >= 2000: "4K"
        case width >= 1600 || height >= 1000: "1080p"
        case width >= 1200 || height >= 700: "720p"
        case width > 0 || height > 0: "SD"
        default: nil
        }
    }
}
