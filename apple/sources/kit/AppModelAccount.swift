import Foundation
import RabbitEarsAPI

extension AppModel {
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
    public func savePreferences(
        for profile: Account, color: String?, hideKidsContent: Bool?, autoplay: Bool? = nil
    ) async throws {
        let client = try signedInClient()
        do {
            _ = try await client.setProfilePreferences(
                path: .init(profileId: profile.id),
                body: .json(.init(color: color?.uppercased(), hideKidsContent: hideKidsContent, autoplay: autoplay))
            ).ok
        } catch {
            throw AppError.from(error, unauthorized: .signedOut)
        }
        await reload()
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
