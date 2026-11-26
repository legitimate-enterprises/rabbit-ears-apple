import Foundation

/// Join codes as the server issues them: `XXXX-XXXX` from 32 symbols
/// without 0, O, 1 or I.
public enum JoinCode {
    static let alphabet = Set("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    /// The canonical code for what was typed, ignoring case, spaces and dashes.
    public static func normalize(_ text: String) -> String? {
        let symbols = text.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard symbols.count == 8, symbols.allSatisfy(alphabet.contains) else { return nil }
        return "\(symbols.prefix(4))-\(symbols.suffix(4))"
    }

    /// The server and code of a join link such as `https://host/join/7KQ4-MNP2`.
    public static func parseLink(_ text: String) -> (server: ServerEndpoint, code: String)? {
        guard text.contains("://"), let url = URL(string: text.trimmingCharacters(in: .whitespaces)),
            url.pathComponents.count == 3, url.pathComponents[1] == "join",
            let code = normalize(url.pathComponents[2]), let server = ServerEndpoint(userInput: text)
        else { return nil }
        return (server, code)
    }
}

/// A join code for an adult added to the household, and its link.
public struct Invite: Equatable, Sendable {
    public let code: String
    public let url: URL
}
