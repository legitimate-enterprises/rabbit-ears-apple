import Foundation
import RabbitEarsAPI

public typealias ItemRelated = Components.Schemas.ItemRelated

/// The way from a detail page to the film or episode before or after it.
public struct Neighbor: Sendable {
    public let item: Item
    public let isNext: Bool

    /// `Previous: The Two Towers`, `Next: S2 E1`.
    public var title: String { "\(isNext ? "Next" : "Previous"): \(name)" }

    /// `Previous film, The Two Towers`, `Next episode, S2 E1`.
    public var accessibilityLabel: String {
        "\(isNext ? "Next" : "Previous") \(item.kind == .episode ? "episode" : "film"), \(name)"
    }

    private var name: String { item.kind == .episode ? Format.episodeCode(item) : Catalog.title(item) }
}

extension ItemRelated {
    /// Previous before Next, each only when there is one.
    public var neighbors: [Neighbor] {
        [previous.map { Neighbor(item: $0, isNext: false) }, next.map { Neighbor(item: $0, isNext: true) }]
            .compactMap { $0 }
    }
}

extension CatalogModel {
    /// nil when neither the server nor the downloads answer, so the page
    /// shows neither the collections nor the neighbors.
    public func related(_ id: Item.ID) async -> ItemRelated? {
        try? await client.getItemRelated(path: .init(itemId: id)).ok.body.json
    }
}

extension Array {
    /// Swaps the page on top of a navigation stack for another, so Back
    /// returns to where the first was opened from.
    public mutating func replaceTop(with page: Element) {
        if isEmpty { append(page) } else { self[count - 1] = page }
    }
}
