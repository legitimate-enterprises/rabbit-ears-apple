import Foundation
import GRDB
import RabbitEarsAPI

extension AppModel {
    func signedInClient() throws -> Client {
        guard let client else { throw AppError.signedOut }
        return client
    }

    /// Replaces the signed-in adult's password; their other devices are signed out.
    public func changePassword(current: String, new: String) async throws {
        let client = try signedInClient()
        do {
            _ = try await client.changePassword(body: .json(.init(currentPassword: current, newPassword: new)))
                .noContent
        } catch {
            if APIError.from(error)?.code == .forbidden { throw AppError.wrongPassword }
            throw AppError.from(error, unauthorized: .signedOut)
        }
    }

    /// Saves a profile's color, as the server's uppercase hex, its
    /// Autoplay, and an adult's Hide kids' content; nil keeps what it has.
    /// Saved here at once, offline too; one the server refuses is told and undone by catch-up.
    public func savePreferences(
        for profile: Account, color: String?, hideKidsContent: Bool?, autoplay: Bool? = nil
    ) async throws {
        guard let sync, let acting = serverActiveProfile?.id else { throw AppError.signedOut }
        do {
            try await sync.queue.setProfilePreferences(
                profile.id, color: color?.uppercased(), hideKidsContent: hideKidsContent, autoplay: autoplay,
                as: acting)
        } catch {
            throw AppError.from(error, unauthorized: .signedOut)
        }
        await reload()
    }

    /// `me` with each profile's color, Autoplay and Hide kids' content as
    /// the replica holds them, which includes this device's unsent changes;
    /// the rest of a profile is the server's, as pinLocked has no column there.
    func replicaSettings(_ me: Components.Schemas.Me) async -> Components.Schemas.Me {
        let ids = [me.account.id] + me.profiles.map(\.id)
        guard
            let rows = try? await sync?.replica.read({ db in
                try SQLRequest<Row>(
                    literal: "SELECT id, color, hide_kids_content, no_autoplay FROM account WHERE id IN \(ids)"
                ).fetchAll(db).map {
                    (
                        id: $0["id"] as UID, color: $0["color"] as String?,
                        hide: $0["hide_kids_content"] as Bool? ?? false,
                        stopped: $0["no_autoplay"] as Bool? ?? false
                    )
                }
            })
        else { return me }
        let settings = Dictionary(rows.map { ($0.id, $0) }) { first, _ in first }
        func settle(_ profile: inout Account) {
            guard let row = settings[profile.id] else { return }
            // As the server's ShownColor: none of its own wears the palette's for its id.
            profile.color =
                row.color.flatMap { $0.isEmpty ? nil : $0 } ?? ProfilePalette.color(for: profile.id)
            profile.autoplay = !row.stopped
            if profile.kind == .adult { profile.hideKidsContent = row.hide }
        }
        var settled = me
        settle(&settled.account)
        for index in settled.profiles.indices { settle(&settled.profiles[index]) }
        return settled
    }

    /// Makes the profile browsing here the server's active one when `me`,
    /// as last heard, names another, as after a switch made offline; one the
    /// server no longer unlocks goes back to Who's watching.
    func unlockSwitchedOffline(_ me: Components.Schemas.Me) async {
        guard phase == .browsing, let active = activeProfile, me.activeProfileId != active.id,
            me.profiles.contains(where: { $0.id == active.id })
        else { return }
        do { try await unlock(active) } catch { if error as? AppError != .unreachable { lockedOut() } }
    }

    /// Rethrows the failed unlock's `error`, unless it says the server is
    /// unreachable and the replica says the profile has no PIN, so this
    /// device switches to it offline.
    func switchOffline(to profile: Account, after error: any Error) async throws {
        let failure = AppError.from(error, unauthorized: .signedOut)
        let id = profile.id
        let hasPin = try? await sync?.replica.read {
            try Bool.fetchOne($0, sql: "SELECT has_pin FROM account WHERE id = ?", arguments: [id])
        }
        guard failure == .unreachable, hasPin == false else { throw failure }
    }

    public func suggestCeilings(for form: AddKidForm) async -> Components.Schemas.CeilingSuggestion? {
        try? await client?.suggestCeilings(query: .init(birthday: form.birthdayString)).ok.body.json
    }

    public func joinPreview(server: String, code: String) async throws -> Components.Schemas.JoinPreview {
        let endpoint = try parse(server)
        guard let code = JoinCode.normalize(code) else { throw AppError.inviteInvalid }
        Task { await learnName(endpoint) }
        do {
            return try await endpoint.client(token: nil, transport: transport).getJoin(path: .init(code: code)).ok
                .body.json
        } catch {
            throw APIError.from(error)?.status == 404 ? AppError.inviteInvalid : AppError.from(error)
        }
    }

    public func acceptJoin(server: String, code: String, name: String, password: String) async throws {
        let endpoint = try parse(server)
        guard let code = JoinCode.normalize(code) else { throw AppError.inviteInvalid }
        let request = Components.Schemas.AcceptRequest(
            name: name, password: password, deviceName: deviceName, platform: platform)
        try await signedIn(endpoint, notFound: .inviteInvalid) {
            try await $0.acceptJoin(path: .init(code: code), body: .json(request)).created.body.json
        }
    }
}
