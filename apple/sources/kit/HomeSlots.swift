import Foundation
import RabbitEarsAPI

/// One of Home's rows that loads after Home first shows, as it last showed:
/// its title and each tile's art, wide (16:9) or not.
public struct HomeSlot: Codable, Equatable, Identifiable, Sendable {
    public enum Row: Codable, Hashable, Sendable {
        case onNow
        case occasion(UID)
    }

    public let row: Row
    public let title: String
    public let wide: [Bool]
    public var id: Row { row }
}

/// What the profile's last Home showed of On now and its occasions, so the
/// next one holds that space until each row's own answer comes. Next up
/// needs none: it comes with the catalog, which Home shows with.
public struct HomeSlots: Codable, Equatable, Sendable {
    public var rows: [HomeSlot] = []

    public func onNow(answered: Bool) -> HomeSlot? { answered ? nil : rows.first { $0.row == .onNow } }

    public func occasions(answered: Bool) -> [HomeSlot] { answered ? [] : rows.filter { $0.row != .onNow } }
}

extension AppModel {
    /// What the profile's last Home showed on this server this launch;
    /// nothing before its first, or after a sign-out.
    public func homeSlots(_ profileId: UID) -> HomeSlots {
        homeSlotsKey(profileId).flatMap { heldHomeSlots[$0] } ?? HomeSlots()
    }

    /// The stations On now showed; none drops the row.
    public func homeShowed(onNow stations: [Station], profileId: UID) {
        var slots = homeSlots(profileId)
        slots.rows.removeAll { $0.row == .onNow }
        if !stations.isEmpty {
            slots.rows.insert(
                HomeSlot(row: .onNow, title: "On now", wide: stations.map { $0.kind != .music }), at: 0)
        }
        keepHomeSlots(slots, profileId)
    }

    /// The occasion shelves Home showed, in order.
    public func homeShowed(occasions shelves: [OccasionShelf], profileId: UID) {
        var slots = homeSlots(profileId)
        slots.rows.removeAll { $0.row != .onNow }
        slots.rows += shelves.map { HomeSlot(row: .occasion($0.id), title: $0.name, wide: $0.items.map { _ in false }) }
        keepHomeSlots(slots, profileId)
    }

    /// Only the active profile's Home is kept.
    private func keepHomeSlots(_ slots: HomeSlots, _ profileId: UID) {
        guard let key = homeSlotsKey(profileId), activeProfile?.id == profileId else { return }
        heldHomeSlots[key] = slots
    }

    private func homeSlotsKey(_ profileId: UID) -> String? {
        endpoint.map { "\(profileId) \($0.baseURL.absoluteString) home rows" }
    }
}
