import CryptoKit
import Foundation
import OpenAPIRuntime
import RabbitEarsAPI
import Synchronization

/// What the last local check found for a server signed in to at a public
/// address: the address that reaches it on its own network, where this
/// device then is too. Every copy of a `ServerEndpoint` shares one.
public final class HomeLink: Sendable {
    /// How long the addresses have to answer; an unreachable private one never does.
    static let patience = Duration.seconds(2)
    /// How long a check stands on the path it was made on; the server forgets one after 15 minutes.
    static let standing: TimeInterval = 600

    private struct State {
        var found: URL?
        var checked: (at: Date, path: PathFacts)?
        /// Where the stream now playing was resolved; a device plays one at a time.
        var streaming: URL?
    }
    private let state = Mutex(State())

    public init() {}

    /// The server's base URL on its own network; nil when the last check found none.
    public var localURL: URL? { state.withLock { $0.found } }

    /// Whether the last check found another address than the stream now
    /// playing was resolved at, which then has to be loaded again.
    public var moved: Bool { state.withLock { $0.streaming != $0.found } }

    /// The address a stream is fetched at, remembered for `moved`.
    func stream() -> URL? {
        state.withLock {
            $0.streaming = $0.found
            return $0.found
        }
    }

    func stands(on path: PathFacts, at now: Date) -> Bool {
        state.withLock { $0.checked.map { $0.path == path && now.timeIntervalSince($0.at) < Self.standing } ?? false }
    }

    /// Opens a check with `client`, then confirms it at every address the
    /// server names at once. The first whose reply proves the key becomes
    /// `localURL`; with none, or on any error, there is none.
    public func refresh(
        client: Client, path: PathFacts, transport: (any ClientTransport)? = nil, now: Date = Date()
    ) async {
        let url = await Self.confirmed(client: client, transport: transport)
        // A cancelled check found nothing out.
        guard !Task.isCancelled else { return }
        state.withLock {
            $0.found = url
            $0.checked = (now, path)
        }
    }

    private static func confirmed(client: Client, transport: (any ClientTransport)?) async -> URL? {
        guard let check = try? await client.startLocalCheck().created.body.json,
            let secret = Data(base64Encoded: check.key)
        else { return nil }
        let key = SymmetricKey(data: secret)
        return await withTaskGroup(of: URL?.self) { race in
            race.addTask {
                await withTaskGroup(of: URL?.self) { attempts in
                    for url in check.addresses.compactMap(URL.init(string:)) {
                        attempts.addTask { try? await confirm(check.id, at: url, key: key, transport: transport) }
                    }
                    defer { attempts.cancelAll() }
                    for await url in attempts where url != nil { return url }
                    return nil
                }
            }
            race.addTask {
                try? await Task.sleep(for: patience)
                return nil
            }
            defer { race.cancelAll() }
            return await race.next() ?? nil
        }
    }

    /// The address, once its reply proves it holds the key as well: at a
    /// private address anything may answer. No token is sent.
    private static func confirm(
        _ check: String, at url: URL, key: SymmetricKey, transport: (any ClientTransport)?
    ) async throws -> URL? {
        let nonce = (UUID().uuidString + UUID().uuidString).replacing("-", with: "")
        let mine = HMAC<SHA256>.authenticationCode(for: Data("client:\(nonce)".utf8), using: key)
        let reply = try await Client.connect(to: url, token: nil, transport: transport).confirmLocalCheck(
            path: .init(checkId: check),
            body: .json(.init(nonce: nonce, proof: mine.map { String(format: "%02x", $0) }.joined()))
        ).ok.body.json
        let theirs = stride(from: 0, to: reply.proof.count, by: 2).compactMap {
            UInt8(reply.proof.dropFirst($0).prefix(2), radix: 16)
        }
        let proven = HMAC<SHA256>.isValidAuthenticationCode(
            theirs, authenticating: Data("server:\(nonce)".utf8), using: key)
        return proven ? url : nil
    }
}
