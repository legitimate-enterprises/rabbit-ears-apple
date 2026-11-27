import Foundation
import OpenAPIRuntime
import RabbitEarsAPI

/// Where the Rabbit Ears server is reached; 8477 matches the server's default port.
public struct ServerEndpoint: Equatable, Hashable, Sendable {
    public static let defaultPort = 8477
    public static let `default` = ServerEndpoint(baseURL: URL(string: "http://localhost:8477")!)

    public let baseURL: URL
    /// What the last local check found. Every copy shares it, and it is no
    /// part of the endpoint's identity.
    public let home = HomeLink()

    public static func == (lhs: ServerEndpoint, rhs: ServerEndpoint) -> Bool { lhs.baseURL == rhs.baseURL }
    public func hash(into hasher: inout Hasher) { hasher.combine(baseURL) }

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    /// Reads what a person types in the Server field: a host, host and port,
    /// or any URL on the server (a join link works). A bare host gets http
    /// and the default port; a URL keeps its own scheme and port.
    public init?(userInput: String) {
        let text = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        let hasScheme = text.contains("://")
        guard var parts = URLComponents(string: hasScheme ? text : "http://\(text)"),
            let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
            let host = parts.host, !host.isEmpty
        else { return nil }
        parts.scheme = scheme
        parts.host = host.lowercased()
        if !hasScheme && parts.port == nil { parts.port = Self.defaultPort }
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        guard let url = parts.url else { return nil }
        self.init(baseURL: url)
    }

    /// A server-relative path from the API, such as a subtitle sidecar, as an absolute URL.
    public func resolve(_ path: String) -> URL {
        URL(string: path, relativeTo: baseURL)?.absoluteURL ?? baseURL
    }

    /// A stream's path as an absolute URL, at the server's own network
    /// address once a local check has confirmed one.
    public func resolveStream(_ path: String) -> URL {
        URL(string: path, relativeTo: home.stream() ?? baseURL)?.absoluteURL ?? baseURL
    }

    /// Whether the server's address is one only a local network reaches.
    public var isLocalNetwork: Bool {
        guard let host = baseURL.host(percentEncoded: false)?.lowercased() else { return false }
        if host == "localhost" || host.hasSuffix(".local") { return true }
        if host.contains(":") {
            return host == "::1" || host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80")
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = labels.compactMap { UInt8($0) }
        guard labels.count == 4, octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (10, _), (127, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        default: return false
        }
    }
}

extension ServerEndpoint {
    /// Whether this device is on the server's own network, by the address
    /// signed in at or by a local check. The playback snapshot reports it as
    /// discovered locally.
    public var atHome: Bool { isLocalNetwork || home.localURL != nil }

    /// Runs a local check through `client`, which is signed in, unless the
    /// address is already local or, when not forced, the last check still
    /// stands: made on `path` within 10 minutes, whatever it found. A check
    /// that fails for any reason means away from home. Tests pass their own
    /// transport and clock.
    public func confirmHome(
        using client: Client, on path: PathFacts, force: Bool = false, transport: (any ClientTransport)? = nil,
        now: Date = Date()
    ) async {
        guard !isLocalNetwork, force || !home.stands(on: path, at: now) else { return }
        await home.refresh(client: client, path: path, transport: transport, now: now)
    }

    /// The snapshot a playback start sends, after the local check its
    /// network group reports.
    public func snapshot(
        _ facts: DeviceFacts, checkedWith client: Client, maxBitrate: Int64?, auto: Bool = false
    ) async -> CapabilitySnapshot {
        await confirmHome(using: client, on: facts.path)
        return CapabilitySnapshotBuilder.snapshot(facts, server: self, maxBitrate: maxBitrate, auto: auto)
    }

    /// A generated API client for this server, signed in as the device when
    /// `token` is given. Error responses throw `APIError`, a device_locked
    /// one after `locked` has run. With `offline`, what is downloaded plays
    /// from the device and answers while the server cannot be reached. Tests
    /// pass their own transport.
    public func client(
        token: String?, transport: (any ClientTransport)? = nil, generation: ArtworkGeneration? = nil,
        offline: DownloadStore? = nil, locked: (@MainActor @Sendable () -> Void)? = nil
    ) -> Client {
        let middlewares: [any ClientMiddleware] =
            (offline.map { [OfflineMiddleware(store: $0)] } ?? []) + [ErrorMiddleware(locked: locked)]
            + (generation.map { [$0] } ?? [])
        return Client.connect(
            to: baseURL, token: token, transport: transport ?? Client.sharedTransport, middlewares: middlewares)
    }
}
