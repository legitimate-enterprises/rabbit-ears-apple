import Foundation
import Observation
import RabbitEarsAPI

public typealias PlaylistShare = Components.Schemas.PlaylistShare
public typealias PlaylistShareAccess = Components.Schemas.PlaylistShareAccess
public typealias ShareCandidate = Components.Schemas.ShareCandidate
public typealias ShareHousehold = Components.Schemas.ShareHousehold
public typealias PlaylistHouseholdShare = Components.Schemas.PlaylistHouseholdShare

extension Playlist {
    /// Only the owner renames, deletes or shares it.
    public var isOwned: Bool { access == .owner }
    /// Whether the profile adds, removes and reorders its entries; a smart one's follow its rules.
    public var isEditable: Bool { access != .read && smart != true }
    /// `Shared by Ann` for a playlist shared with the profile.
    public var sharedBy: String? { ownerName.map { "Shared by \($0)" } }
    /// Whether its artwork carries the Shared badge; a copy kept without the flag is not shared.
    public var isShared: Bool { shared ?? false }
}

extension PlaylistShareAccess {
    public var label: String { self == .read ? "Can view" : "Can edit" }
}

extension PlaylistShareAccess? {
    public var label: String { map(\.label) ?? "Not shared" }
}

extension ShareHousehold {
    public var profilesLabel: String { "\(profiles) profile" + (profiles == 1 ? "" : "s") }
}

/// A profile the owner may share with, or already does.
public struct ShareProfile: Identifiable, Hashable, Sendable {
    public let id: UID
    public let name: String
    /// Its household when the owner is in more than one, and Kid for a kid.
    public let subtitle: String?
    /// The accesses it may have; a kid only views.
    public let choices: [PlaylistShareAccess]
    /// Its color as 0xRRGGBB, for its initial's circle; nil when the server sent none.
    public let rgb: UInt32?

    init(
        id: UID, name: String, kind: Components.Schemas.AccountKind, color: String?, household: String?
    ) {
        self.id = id
        self.name = name
        rgb = color.flatMap(ProfilePalette.rgb)
        let kid = kind == .kid
        let parts = [household, kid ? "Kid" : nil].compactMap(\.self)
        subtitle = parts.isEmpty ? nil : parts.joined(separator: " · ")
        choices = kid ? [.read] : PlaylistShareAccess.allCases
    }
}

/// The owner's view of whom one playlist is shared with, households and
/// profiles, and everyone else it can go to. Each change applies at once.
@MainActor
@Observable
public final class PlaylistSharesModel {
    public private(set) var households: [ShareHousehold] = []
    public private(set) var householdShares: [PlaylistHouseholdShare] = []
    public private(set) var shares: [PlaylistShare] = []
    public private(set) var candidates: [ShareCandidate] = []
    public private(set) var error: String?
    public let client: Client
    public let queue: ActionQueue
    public let profileId: UID
    public let playlistId: UID

    public init(client: Client, queue: ActionQueue, profileId: UID, playlistId: UID) {
        self.client = client
        self.queue = queue
        self.profileId = profileId
        self.playlistId = playlistId
    }

    /// The candidates, then anyone it is shared with who is no longer one.
    public var profiles: [ShareProfile] {
        let named = households.count > 1 ? households : []
        let household = { (id: UID?) in named.first { $0.id == id }?.name }
        let listed = candidates.map {
            ShareProfile(
                id: $0.profileId, name: $0.name, kind: $0.kind, color: $0.color, household: household($0.householdId))
        }
        let others = shares.filter { share in !candidates.contains { $0.profileId == share.profileId } }
        return listed
            + others.map {
                ShareProfile(
                    id: $0.profileId, name: $0.name, kind: $0.kind, color: $0.color,
                    household: household($0.householdId))
            }
    }

    public func access(_ household: ShareHousehold) -> PlaylistShareAccess? {
        householdShares.first { $0.householdId == household.id }?.access
    }

    public func access(_ profile: ShareProfile) -> PlaylistShareAccess? {
        shares.first { $0.profileId == profile.id }?.access
    }

    public func load() async {
        await write {
            households = try await client.listShareHouseholds(path: .init(profileId: profileId)).ok.body.json.items
            householdShares = try await allPages { offset in
                let page = try await self.client.listPlaylistHouseholdShares(
                    path: .init(profileId: self.profileId, playlistId: self.playlistId),
                    query: .init(limit: 200, offset: offset)
                ).ok.body.json
                return (page.items, page.nextOffset)
            }
            shares = try await allPages { offset in
                let page = try await self.client.listPlaylistShares(
                    path: .init(profileId: self.profileId, playlistId: self.playlistId),
                    query: .init(limit: 200, offset: offset)
                ).ok.body.json
                return (page.items, page.nextOffset)
            }
            candidates = try await allPages { offset in
                let page = try await self.client.listShareCandidates(
                    path: .init(profileId: self.profileId), query: .init(limit: 200, offset: offset)
                ).ok.body.json
                return (page.items, page.nextOffset)
            }
        }
    }

    /// Creates, replaces or deletes the household's share; nil is Not shared.
    /// It is queued, so what shows is the change made here until the next load.
    public func set(_ household: ShareHousehold, to access: PlaylistShareAccess?) async {
        await write {
            try await queue.share(
                as: profileId, playlistId, withHousehold: household.id, from: self.access(household), to: access)
            householdShares.removeAll { $0.householdId == household.id }
            if let access {
                householdShares.append(
                    .init(
                        playlistId: playlistId, householdId: household.id, name: household.name, access: access,
                        createdAt: .now))
            }
        }
    }

    /// Creates, replaces or deletes the profile's share; nil is Not shared.
    /// It is queued, so what shows is the change made here until the next load.
    public func set(_ profile: ShareProfile, to access: PlaylistShareAccess?) async {
        await write {
            let old = shares.first { $0.profileId == profile.id }
            try await queue.share(as: profileId, playlistId, with: profile.id, from: old?.access, to: access)
            shares.removeAll { $0.profileId == profile.id }
            guard let access else { return }
            if var old {
                old.access = access
                shares.append(old)
            } else if let candidate = candidates.first(where: { $0.profileId == profile.id }) {
                shares.append(
                    .init(
                        playlistId: playlistId, profileId: profile.id, name: candidate.name, kind: candidate.kind,
                        access: access, createdAt: .now, color: candidate.color, householdId: candidate.householdId))
            }
        }
    }

    @discardableResult
    private func write(_ body: () async throws -> Void) async -> Bool {
        do {
            try await body()
            error = nil
            return true
        } catch {
            self.error = AppError.from(error, unauthorized: .signedOut).localizedDescription
            return false
        }
    }
}
