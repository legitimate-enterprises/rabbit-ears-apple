import Foundation
import GRDB
import Observation
import RabbitEarsAPI

/// What the active profile may do to one member of the household.
public struct MemberActions: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let editKid = MemberActions(rawValue: 1 << 0)
    public static let setPin = MemberActions(rawValue: 1 << 1)
    public static let remove = MemberActions(rawValue: 1 << 2)
    public static let resendCode = MemberActions(rawValue: 1 << 3)
    public static let makeAdult = MemberActions(rawValue: 1 << 4)
    public static let share = MemberActions(rawValue: 1 << 5)

    /// Any adult edits, removes, shares and sets PINs for kids, shares any
    /// joined adult of the household and removes an adult only visiting it;
    /// each adult sets their own PIN; only the owner manages other adults
    /// and makes kids adults.
    public static func allowed(for member: Account, active: Account?, ownerId: Account.ID?) -> MemberActions {
        guard let active, active.kind == .adult else { return [] }
        if member.present == true { return [.remove] }
        let owner = active.id == ownerId
        if member.kind == .kid {
            return owner ? [.editKid, .setPin, .share, .remove, .makeAdult] : [.editKid, .setPin, .share, .remove]
        }
        if member.id == active.id { return [.setPin, .share] }
        if member.pending { return owner ? [.resendCode, .remove] : [] }
        return owner ? [.share, .remove] : [.share]
    }
}

public typealias ProfileOffer = Components.Schemas.ProfileOffer

extension Account {
    /// In another household too, so removing it here only takes it out of this one.
    public var shared: Bool { (households ?? 1) > 1 || present == true }
}

/// What removing a member asks and says; a shared one only leaves this household.
public enum Removal {
    public static func title(_ member: Account) -> String {
        member.shared ? "Remove from this household…" : "Remove…"
    }

    public static func question(_ member: Account) -> String {
        member.shared ? "Remove \(member.name) from this household?" : "Remove \(member.name)?"
    }

    public static func message(_ member: Account) -> String {
        if member.shared {
            let others = (member.households ?? 1) > 2 ? "households" : "household"
            return "\(member.name) stays in their other \(others), and nothing of theirs is deleted."
        }
        if member.kind == .kid { return "Their account and watch history are deleted." }
        return member.pending ? "Their code stops working." : "Their devices are signed out."
    }
}

/// The manage-household sheet: every member the server lists for the active
/// profile, and the changes it may make to them.
@MainActor
@Observable
public final class HouseholdModel {
    public private(set) var members: [Account] = []
    /// Offers made to the active adult, and those of this household's profiles.
    public private(set) var offers = Components.Schemas.ProfileOfferList(incoming: [], outgoing: [])
    public private(set) var error: String?
    private let app: AppModel

    public init(app: AppModel) { self.app = app }

    /// The active adult only visits this household, so may only leave it.
    public var visiting: Bool { app.serverActiveProfile?.present == true }
    /// Whether any member is in another household too, which the list explains.
    public var anyShared: Bool { members.contains(where: \.shared) }

    public func actions(for member: Account) -> MemberActions {
        MemberActions.allowed(
            for: member, active: app.canManageHousehold ? app.serverActiveProfile : nil,
            ownerId: app.me?.household?.adultId)
    }

    public func load() async {
        do {
            let client = try app.signedInClient()
            members = try await client.listProfiles().ok.body.json.items.filter { $0.revokedAt == nil }
            offers = try await client.listProfileOffers().ok.body.json
            error = nil
        } catch {
            self.error = AppError.from(error, unauthorized: .signedOut).localizedDescription
        }
    }

    public func saveKid(_ kid: Account, _ form: AddKidForm) async throws {
        try await change {
            _ = try await $0.replaceProfile(path: .init(profileId: kid.id), body: .json(form.input)).ok
            switch form.pinChange {
            case .keep: break
            case .clear: _ = try await $0.clearProfilePin(path: .init(profileId: kid.id)).noContent
            case .set(let pin):
                _ = try await $0.setProfilePin(path: .init(profileId: kid.id), body: .json(.init(pin: pin))).noContent
            }
        }
    }

    /// Sets the member's PIN, or removes it when nil.
    public func setPin(_ member: Account, _ pin: String?) async throws {
        try await change {
            if let pin {
                _ = try await $0.setProfilePin(path: .init(profileId: member.id), body: .json(.init(pin: pin)))
                    .noContent
            } else {
                _ = try await $0.clearProfilePin(path: .init(profileId: member.id)).noContent
            }
        }
    }

    /// The titles a kid on an allow list may see, as getItem finds each for
    /// the active profile; a channel or a title it does not find is left out.
    public func allowed(_ kid: Account) async throws -> [Item] {
        let (kidId, viewer) = (kid.id, try acting())
        return try await read { db in
            let ids = try UID.fetchAll(
                db, sql: "SELECT item_id FROM account_allow WHERE account_id = ? ORDER BY item_id", arguments: [kidId])
            let items = try ReplicaRows.items(
                db,
                "i.id IN (SELECT unhex(value, '-') FROM json_each(?))"
                    + " AND i.id IN (SELECT item_id FROM profile_item_open WHERE account_id = ?)",
                [ReplicaRows.json(ids), viewer])
            return Self.ordered(items, ids)
        }
    }

    /// Movies and shows matching the query, the only kinds an allow list
    /// holds, from the first page of 20 listItems answers for it.
    public func findTitles(_ query: String) async throws -> [Item] {
        let viewer = try acting()
        return try await read { db in
            let page = try UID.fetchAll(
                db,
                sql: """
                    SELECT i.id FROM item i WHERE i.id IN (SELECT unhex(value, '-') FROM json_each(?))
                        AND i.id IN (SELECT item_id FROM profile_item WHERE account_id = ?)
                    ORDER BY \(ReplicaRows.titleOrder) LIMIT 20
                    """, arguments: [ReplicaRows.json(try ReplicaSearch.items(matching: query, in: db)), viewer])
            return Self.ordered(
                try ReplicaRows.items(
                    db, "i.id IN (SELECT unhex(value, '-') FROM json_each(?))", [ReplicaRows.json(page)]), page
            )
            .filter { $0.kind == .movie || $0.kind == .show }
        }
    }

    /// The kids of the device's household on an allow list whose list holds this title or channel.
    public func allowedFor(_ itemId: UID) async throws -> Set<Account.ID> {
        try await read { db in
            Set(
                try UID.fetchAll(
                    db,
                    sql: """
                        SELECT a.id FROM account a JOIN account_allow w ON w.account_id = a.id
                        WHERE a.id IN (SELECT account_id FROM household_member
                                WHERE household_id = (SELECT household_id FROM replica_meta))
                            AND a.kind = 'kid' AND a.filter_mode = 'allow_list' AND w.item_id = ?
                        """, arguments: [itemId]))
        }
    }

    public func allow(_ kid: Account, _ itemId: Item.ID) async throws {
        try await write { try await $0.allowItem(itemId, for: kid.id, as: $1) }
        app.allowLists.record(kid.id, allowed: true, for: itemId)
    }

    public func disallow(_ kid: Account, _ itemId: Item.ID) async throws {
        try await write { try await $0.disallowItem(itemId, for: kid.id, as: $1) }
        app.allowLists.record(kid.id, allowed: false, for: itemId)
    }

    public func remove(_ member: Account) async throws {
        try await change { _ = try await $0.deleteProfile(path: .init(profileId: member.id)).noContent }
    }

    public func accept(_ offer: ProfileOffer) async throws {
        try await change { _ = try await $0.acceptProfileOffer(path: .init(offerId: offer.id)).noContent }
    }

    /// Declines an offer made to the active adult, or withdraws one of this household.
    public func cancel(_ offer: ProfileOffer) async throws {
        try await change { _ = try await $0.deleteProfileOffer(path: .init(offerId: offer.id)).noContent }
    }

    /// The adults of other households the server's admin connected the active adult with.
    public func connectedAdults() async throws -> [Account] {
        // shortcut: one page of 200, as an admin connects an adult with a few others; page it if that grows.
        try await call { try await $0.listLinkedAdults(query: .init(limit: 200)).ok.body.json.items }
    }

    /// Offers a member to a connected adult, for their own household.
    public func offer(_ member: Account, to adult: Account) async throws {
        try await change {
            _ = try await $0.createProfileOffer(body: .json(.init(profileId: member.id, toProfileId: adult.id)))
                .created
        }
    }

    /// The visiting adult leaves this household. The server signs out their
    /// own devices there, so this device signs out when it is theirs;
    /// another goes back to Who's watching.
    public func leave() async throws {
        guard let visitor = app.serverActiveProfile else { return }
        try await call { _ = try await $0.deleteProfile(path: .init(profileId: visitor.id)).noContent }
        if visitor.id == app.me?.account.id { return await app.signOut() }
        await app.reload()
        await app.switchProfile()
    }

    /// A fresh 7-day code for a pending adult; their unused ones stop working.
    public func resendCode(_ member: Account) async throws -> Invite {
        app.invite(
            try await change { try await $0.resendProfileJoinCode(path: .init(profileId: member.id)).created.body.json }
        )
    }

    /// Turns a kid into a pending adult, who joins with the returned code.
    public func makeAdult(_ member: Account, email: String) async throws -> Invite {
        app.invite(
            try await change(conflict: .emailTaken) {
                try await $0.makeProfileAdult(path: .init(profileId: member.id), body: .json(.init(email: email)))
                    .created.body.json
            })
    }

    /// The profile the server answers as, whose reads and writes these are.
    private func acting() throws -> UID {
        guard let id = app.serverActiveProfile?.id else { throw AppError.signedOut }
        return id
    }

    private func read<T: Sendable>(_ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        guard let replica = app.sync?.replica else { throw AppError.signedOut }
        do { return try await replica.read(body) } catch { throw AppError.from(error) }
    }

    private func write(_ action: (ActionQueue, UID) async throws -> Void) async throws {
        guard let queue = app.sync?.queue else { throw AppError.signedOut }
        do { try await action(queue, try acting()) } catch { throw AppError.from(error) }
    }

    private nonisolated static func ordered(_ items: [Item], _ ids: [UID]) -> [Item] {
        let byId = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        return ids.compactMap { byId[$0] }
    }

    /// Runs one request that leaves the members as they are.
    private func call<T>(_ request: (Client) async throws -> T) async throws -> T {
        do {
            return try await request(app.signedInClient())
        } catch {
            throw AppError.from(error, unauthorized: .signedOut)
        }
    }

    /// Runs one change, then re-reads the members and Who's watching.
    @discardableResult
    private func change<T>(conflict: AppError? = nil, _ call: (Client) async throws -> T) async throws -> T {
        let result: T
        do {
            result = try await call(app.signedInClient())
        } catch {
            if let conflict, APIError.from(error)?.code == .conflict { throw conflict }
            throw AppError.from(error, unauthorized: .signedOut)
        }
        await load()
        await app.reload()
        return result
    }
}
