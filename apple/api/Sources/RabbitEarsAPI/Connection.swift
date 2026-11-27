import Foundation
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession

public struct BearerAuth: ClientMiddleware {
    let token: String

    public init(token: String) { self.token = token }

    public func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        request.headerFields[.authorization] = "Bearer \(token)"
        return try await next(request, body, baseURL)
    }
}

extension Client {
    /// The session every client without its own transport shares. An answer
    /// stalled half a minute fails, rather than after URLSession's minute.
    /// Made on first use, so it takes the URLCache an app sets at launch.
    public static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.urlCache = .shared
        return URLSession(configuration: config)
    }()

    /// What every client made without a transport of its own sends through.
    public static var sharedTransport: any ClientTransport {
        URLSessionTransport(configuration: .init(session: session))
    }

    /// `server` is scheme, host and port. A nil token suits sign in and join
    /// only. `middlewares` run before the token is added.
    public static func connect(
        to server: URL,
        token: String?,
        transport: (any ClientTransport)? = nil,
        middlewares: [any ClientMiddleware] = []
    ) -> Client {
        Client(
            serverURL: server.appending(path: "api/v2"),
            configuration: Configuration(dateTranscoder: ServerDates()),
            transport: transport ?? sharedTransport,
            middlewares: middlewares + (token.map { [BearerAuth(token: $0)] } ?? [])
        )
    }
}

/// Reads the server's instants, which carry fractional seconds only when
/// they are not whole seconds; writes them with milliseconds.
public struct ServerDates: DateTranscoder {
    public init() {}

    public func encode(_ date: Date) throws -> String {
        try ISO8601DateTranscoder.iso8601WithFractionalSeconds.encode(date)
    }

    public func decode(_ string: String) throws -> Date {
        do {
            return try ISO8601DateTranscoder.iso8601WithFractionalSeconds.decode(string)
        } catch {
            return try ISO8601DateTranscoder.iso8601.decode(string)
        }
    }
}
