import Foundation
import Observation
import RabbitEarsAPI
import SwiftUI

public typealias ActiveOccasion = Components.Schemas.ActiveOccasion

extension ActiveOccasion {
    /// The server's playful phrase for a Home row, else the occasion's name.
    public var rowTitle: String {
        guard let headline, !headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return name }
        return headline
    }
}

/// One in-season occasion and the titles the server lists for it.
public struct OccasionShelf: Identifiable, Sendable {
    public let occasion: ActiveOccasion
    public let items: [Item]
    public var id: Int64 { occasion.id }
    /// What the occasion is called on its own screen and in labels.
    public var name: String { occasion.name }
    /// What titles the row on Home.
    public var title: String { occasion.rowTitle }
}

/// Home's seasonal shelves, in the order the server gives them. The server
/// decides which occasions are in season on the device's calendar day and
/// which titles the profile may see; this shows exactly that.
@MainActor
@Observable
public final class OccasionsModel {
    public private(set) var shelves: [OccasionShelf] = []
    /// A load has answered, with shelves or without, so Home holds their space no longer.
    public private(set) var answered = false

    public init() {}

    /// A request that fails keeps what shows; a shelf whose titles fail is left out.
    public func load(client: Client, profileId: Int64, now: Date = Date(), timeZone: TimeZone = .current) async {
        let date = Self.day(now, in: timeZone)
        guard
            let active = try? await client.listActiveOccasions(
                path: .init(profileId: profileId), query: .init(date: date)
            )
            .ok.body.json.items
        else {
            if !Task.isCancelled { answered = true }
            return
        }
        let loaded = await Self.shelves(of: active, client: client)
        guard !Task.isCancelled else { return }
        shelves = loaded
        answered = true
    }

    /// The first titles of each occasion, in the order given; one the server could
    /// not answer, or left with no title but `excluding`, is left out.
    nonisolated static func shelves(
        of active: [ActiveOccasion], client: Client, excluding itemId: Int64? = nil
    ) async -> [OccasionShelf] {
        let loaded = await withTaskGroup(of: (Int, OccasionShelf?).self) { group in
            for (index, occasion) in active.enumerated() {
                group.addTask {
                    // One more than a row shows, so leaving the title out still fills it.
                    let page = try? await client.listItems(
                        query: .init(occasionId: occasion.id, limit: Catalog.homeShelfLimit + (itemId == nil ? 0 : 1))
                    ).ok.body.json
                    let items = (page?.items ?? []).filter { $0.id != itemId }.prefix(Catalog.homeShelfLimit)
                    return (index, page == nil ? nil : OccasionShelf(occasion: occasion, items: Array(items)))
                }
            }
            var done: [(Int, OccasionShelf?)] = []
            for await result in group { done.append(result) }
            return done
        }
        return loaded.sorted { $0.0 < $1.0 }.compactMap { $0.1 }.filter { !$0.items.isEmpty }
    }

    /// `YYYY-MM-DD` on the device's calendar day, whatever its locale or calendar.
    nonisolated static func day(_ date: Date, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
}

extension CatalogModel {
    /// Every title the profile may see in an occasion, a page at a time, for its own screen.
    public func occasionMembers(_ id: Int64) -> Pager<Item> {
        Pager { offset in
            let page = try await self.client.listItems(query: .init(occasionId: id, limit: 200, offset: offset))
                .ok.body.json
            return (page.items, page.nextOffset)
        }
    }

    /// A details page's rows: each occasion in season the title is in, with its other titles.
    public func occasionRows(
        containing itemId: Int64, now: Date = Date(), timeZone: TimeZone = .current
    ) async -> [OccasionShelf] {
        guard
            let active = try? await client.listActiveOccasions(
                path: .init(profileId: profileId),
                query: .init(date: OccasionsModel.day(now, in: timeZone), itemId: itemId)
            )
            .ok.body.json.items
        else { return [] }
        return await OccasionsModel.shelves(of: active, client: client, excluding: itemId)
    }
}

/// Reloads Home's occasion shelves when Home appears, the catalog or profile
/// changes, the app returns to the foreground and the local day turns over.
private struct OccasionReload: ViewModifier {
    let occasions: OccasionsModel
    let catalog: CatalogModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppModel.self) private var app
    @State private var days = 0

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in days += 1 }
            .task(id: "\(catalog.profileId)/\(catalog.revision)/\(scenePhase == .active)/\(days)") {
                guard scenePhase == .active else { return }
                await occasions.load(client: catalog.client, profileId: catalog.profileId)
                guard occasions.answered, !Task.isCancelled else { return }
                app.homeShowed(occasions: occasions.shelves, profileId: catalog.profileId)
            }
    }
}

extension View {
    public func reloadingOccasions(_ occasions: OccasionsModel, with catalog: CatalogModel) -> some View {
        modifier(OccasionReload(occasions: occasions, catalog: catalog))
    }
}
