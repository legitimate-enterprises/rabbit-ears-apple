import Foundation
import RabbitEarsAPI

public typealias AccountDeletion = Components.Schemas.AccountDeletion

extension AccountDeletion {
    /// The server's only admin keeps their account until another is made an admin.
    public var allowed: Bool { outcome != .refused }

    /// What the confirmation says deleting the account takes with it.
    public var summary: String {
        if outcome == .refused {
            return "You are the server's only admin, so your account stays until you make another account an admin"
                + " in the admin console."
        }
        let what =
            "This deletes your account for good, with your watch history, your playlists and the stations that play"
            + " them, and your stations, and signs out every device signed in as you. It cannot be undone."
        switch outcome {
        case .transfer:
            return
                "\(what) The household stays, with its kids, and \(newOwnerName ?? "another adult") becomes its owner."
        case .household:
            let kids = kidNames.isEmpty ? "" : ", with \(Self.joined(kidNames)) and everything of theirs"
            return "\(what) You are the household's only adult, so the household goes too\(kids)."
        default:
            return "\(what) The household stays as it is."
        }
    }

    /// "Mia", "Mia and Leo", "Mia, Leo and Ada".
    static func joined(_ names: [String]) -> String {
        guard let last = names.last, names.count > 1 else { return names.first ?? "" }
        return "\(names.dropLast().joined(separator: ", ")) and \(last)"
    }
}

extension AppModel {
    /// What deleting the active adult's own account takes with it, for the confirmation to say.
    public func accountDeletion() async throws -> AccountDeletion {
        let client = try signedInClient()
        do {
            return try await client.getAccountDeletion().ok.body.json
        } catch {
            throw AppError.from(error, unauthorized: .signedOut)
        }
    }

    /// Deletes the active adult's own account with its password, then signs this device out.
    public func deleteAccount(password: String) async throws {
        let client = try signedInClient()
        do {
            _ = try await client.deleteOwnAccount(body: .json(.init(password: password))).noContent
        } catch {
            if APIError.from(error)?.code == .forbidden { throw AppError.wrongPassword }
            throw AppError.from(error, unauthorized: .signedOut)
        }
        await signOut()
    }
}
