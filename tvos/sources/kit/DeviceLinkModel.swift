import Foundation
import Observation

/// Link a TV on this Apple TV: asks the server for a code, shows it, and
/// polls until an adult approves it elsewhere, which signs the app in.
@MainActor
@Observable
public final class DeviceLinkModel {
    public enum State: Equatable, Sendable {
        case starting, waiting, expired, denied
        case failed(String)
    }

    public let server: ServerEndpoint
    public private(set) var link: DeviceLink?
    public private(set) var state = State.starting
    @ObservationIgnored private let app: AppModel
    @ObservationIgnored private let interval: Duration

    /// The server asks for a poll every 5 seconds.
    public init(app: AppModel, server: ServerEndpoint, interval: Duration = .seconds(5)) {
        self.app = app
        self.server = server
        self.interval = interval
    }

    /// Run it in a task; Get a new code runs it again.
    public func run() async {
        link = nil
        state = .starting
        let link: DeviceLink
        do {
            link = try await app.requestLink(server: server)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        self.link = link
        state = .waiting
        // The server answered, so it is the one to name; the code shows meanwhile.
        Task { await app.learnName(server) }
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            // An unreachable server or a server error keeps waiting; the code may still be approved.
            guard let status = try? await app.pollLink(link, server: server) else { continue }
            switch status {
            case .pending: continue
            // The approval that signs in moves the app on; one without the token was handed over already.
            case .approved: if app.phase != .signedOut { return }
            case .denied:
                state = .denied
                return
            case .expired:
                state = .expired
                return
            }
        }
    }

    /// `rabbit.example.com:8477/link`: what to type where the QR code cannot be scanned.
    public var address: String {
        let url = server.baseURL
        let host = url.host(percentEncoded: false) ?? ""
        return (url.port.map { "\(host):\($0)" } ?? host) + "/link"
    }

    /// The server's QR image of the link; the poll token rides in the query.
    public var qrURL: URL? {
        guard let link else { return nil }
        var components = URLComponents(
            url: server.baseURL.appending(path: "api/v1/device-links/\(link.id)/qr"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "token", value: link.pollToken)]
        return components?.url
    }

    /// `9:41` until the code runs out; nil once it has.
    public func countdown(at now: Date) -> String? {
        guard let link else { return nil }
        let left = link.expiresAt.timeIntervalSince(now)
        return left > 0 ? Format.clock(seconds: left.rounded(.up)) : nil
    }
}
