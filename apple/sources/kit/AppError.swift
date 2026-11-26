import Foundation
import OpenAPIRuntime

/// What went wrong, in the words the account boards use.
public enum AppError: Error, Equatable, LocalizedError {
    case badServer
    case unreachable
    case insecureServer
    case wrongCredentials
    case inviteInvalid
    case wrongPin
    case pinLocked
    case pinRequired
    case wrongPassword
    case emailTaken
    case tooManyAttempts(minutes: Int)
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .badServer: "Enter a server address, such as media.example.com."
        case .unreachable: "Can't reach that server."
        case .insecureServer: "Use https:// for a server outside your home network."
        case .wrongCredentials: "Email or password is wrong."
        case .inviteInvalid: "This invite is no longer valid. Ask for a new one."
        case .wrongPin: "Wrong PIN."
        case .pinLocked: "Too many tries. Try again in 15 minutes."
        case .pinRequired: "This profile needs its PIN."
        case .wrongPassword: "The current password is wrong."
        case .emailTaken: "That email already has an account."
        case .tooManyAttempts(let minutes):
            "Too many attempts. Try again in \(minutes) \(minutes == 1 ? "minute" : "minutes")."
        case .server(let message): message
        }
    }

    /// What a 401 means on a call made while signed in: the session ended.
    static let signedOut = AppError.server("Signed out.")

    /// Maps a thrown error; `unauthorized` names what a 401 means where it was made.
    static func from(_ error: any Error, unauthorized: AppError = .wrongCredentials) -> AppError {
        if let error = error as? AppError { return error }
        guard let api = APIError.from(error) else {
            let underlying = (error as? ClientError)?.underlyingError ?? error
            guard let url = underlying as? URLError else { return .server(underlying.localizedDescription) }
            // App Transport Security lets plain http reach only local addresses.
            return url.code == .appTransportSecurityRequiresSecureConnection ? .insecureServer : .unreachable
        }
        switch api.code {
        case .unauthorized: return unauthorized
        case .pinLocked: return .pinLocked
        case .pinRequired: return .pinRequired
        case .tooManyRequests: return .tooManyAttempts(minutes: max(1, ((api.retryAfter ?? 60) + 59) / 60))
        default: return .server(api.message)
        }
    }
}
