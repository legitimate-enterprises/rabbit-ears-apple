import Foundation
import Observation
import RabbitEarsAPI

/// What a movie's, show's, season's or episode's menu offers the active profile beyond watched
/// and Download: the same on details and in a tile's long-press or right-click menu.
public struct ItemMenuActions: Equatable, Sendable {
    /// Kids' content and Use rating, a movie's or a show's; seasons and episodes follow their show.
    public let kidsRules: Bool
    /// Allowed for kids on a list, for the same titles and only when a kid is on a list.
    public let allowList: Bool
    /// Add to playlist and Add to station; adults only, since kids have neither.
    public let addTo: Bool
    /// Add to collection, on a movie.
    public let addToCollection: Bool

    public init(kind: ItemKind, adult: Bool, allowListKids: Bool) {
        kidsRules = adult && (kind == .movie || kind == .show)
        allowList = kidsRules && allowListKids
        addTo = adult
        addToCollection = adult && kind == .movie
    }
}

extension AppModel {
    public func itemMenuActions(_ kind: ItemKind) -> ItemMenuActions {
        ItemMenuActions(kind: kind, adult: activeProfile?.kind == .adult, allowListKids: !allowListKids.isEmpty)
    }
}

/// Which kids' allow lists hold each title, read once for a menu whose items never appear and
/// so cannot load as it opens. Kept in step by allow and disallow.
@MainActor
@Observable
public final class AllowLists {
    private var holders: [Item.ID: Set<Account.ID>] = [:]

    public init() {}

    public func kids(holding itemId: Item.ID) -> Set<Account.ID> { holders[itemId] ?? [] }

    public func set(_ kids: Set<Account.ID>, for itemId: Item.ID) { holders[itemId] = kids }

    func record(_ kid: Account.ID, allowed: Bool, for itemId: Item.ID) {
        if allowed { holders[itemId, default: []].insert(kid) } else { holders[itemId]?.remove(kid) }
    }

    /// Replaces everything known with each kid's own list; a list that fails to load holds nothing.
    public func load(kids: [Account], client: Client) async {
        var next: [Item.ID: Set<Account.ID>] = [:]
        for kid in kids {
            guard let ids = try? await client.listAllowedItems(path: .init(profileId: kid.id)).ok.body.json.itemIds
            else { continue }
            for id in ids { next[id, default: []].insert(kid.id) }
        }
        holders = next
    }
}
