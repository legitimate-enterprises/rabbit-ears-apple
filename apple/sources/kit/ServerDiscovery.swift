import Foundation
import Network
import Observation

/// A server found on the local network: its advertised name and where it answers.
public struct FoundServer: Equatable, Hashable, Sendable {
    public let name: String
    public let endpoint: ServerEndpoint

    public init(name: String, endpoint: ServerEndpoint) {
        self.name = name
        self.endpoint = endpoint
    }

    /// `192.168.1.20`, with the port only when it is not the default.
    public var address: String {
        let host = endpoint.baseURL.host(percentEncoded: false) ?? ""
        let port = endpoint.baseURL.port
        return port == nil || port == ServerEndpoint.defaultPort ? host : "\(host):\(port!)"
    }
}

/// Finds servers advertising `_rabbit-ears._tcp`; Bonjour in the apps, a fake in tests.
@MainActor
public protocol ServerBrowser: AnyObject {
    /// Every server resolved so far, each time that set changes.
    var onChange: (([FoundServer]) -> Void)? { get set }
    /// True once browsing runs; false when it cannot, as when local network access is denied.
    var onAvailability: ((Bool) -> Void)? { get set }
    func start()
    func stop()
}

/// Choose a server: what the browser finds, by name.
@MainActor
@Observable
public final class ServerDiscovery {
    public private(set) var servers: [FoundServer] = []
    /// Nil until the browser says whether it may run.
    public private(set) var available: Bool?
    @ObservationIgnored private let browser: any ServerBrowser

    public init(browser: any ServerBrowser) {
        self.browser = browser
        browser.onChange = { [weak self] found in
            guard let self else { return }
            servers = Set(found).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        browser.onAvailability = { [weak self] available in self?.available = available }
    }

    public convenience init() { self.init(browser: BonjourBrowser()) }

    public func start() { browser.start() }

    /// Search again: forgets what was found and browses afresh.
    public func restart() {
        stop()
        start()
    }

    public func stop() {
        browser.stop()
        servers = []
        available = nil
    }
}

/// Bonjour through Network.framework. A service resolves to an address only
/// by connecting to it; IPv4 only, because a scoped link-local IPv6 address
/// cannot go in a URL.
@MainActor
public final class BonjourBrowser: ServerBrowser {
    public static let serviceType = "_rabbit-ears._tcp"
    public var onChange: (([FoundServer]) -> Void)?
    public var onAvailability: ((Bool) -> Void)?
    private var browser: NWBrowser?
    private var resolving: [NWEndpoint: NWConnection] = [:]
    private var found: [NWEndpoint: FoundServer] = [:]

    public init() {}

    public func start() {
        stop()
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: .tcp)
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.changed(state) }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.update(Set(results.map(\.endpoint))) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        for connection in resolving.values { connection.cancel() }
        resolving = [:]
        found = [:]
    }

    private func changed(_ state: NWBrowser.State) {
        switch state {
        case .ready: onAvailability?(true)
        // Waiting carries a local network denial; it may turn ready later.
        case .waiting, .failed: onAvailability?(false)
        default: break
        }
    }

    private func update(_ endpoints: Set<NWEndpoint>) {
        for endpoint in found.keys where !endpoints.contains(endpoint) { found[endpoint] = nil }
        for endpoint in resolving.keys where !endpoints.contains(endpoint) {
            resolving.removeValue(forKey: endpoint)?.cancel()
        }
        for endpoint in endpoints where found[endpoint] == nil && resolving[endpoint] == nil { resolve(endpoint) }
        onChange?(Array(found.values))
    }

    private func resolve(_ service: NWEndpoint) {
        guard case .service(let name, _, _, _) = service else { return }
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let connection = NWConnection(to: service, using: parameters)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            MainActor.assumeIsolated {
                guard let connection else { return }
                self?.changed(state, of: connection, to: service, named: name)
            }
        }
        resolving[service] = connection
        connection.start(queue: .main)
    }

    private func changed(
        _ state: NWConnection.State, of connection: NWConnection, to service: NWEndpoint, named name: String
    ) {
        switch state {
        case .ready:
            if case .hostPort(.ipv4(let address), let port) = connection.currentPath?.remoteEndpoint,
                let endpoint = ServerEndpoint(userInput: "\(address):\(port.rawValue)")
            {
                found[service] = FoundServer(name: name, endpoint: endpoint)
                onChange?(Array(found.values))
            }
            connection.cancel()
        case .failed, .waiting: connection.cancel()
        case .cancelled: if resolving[service] === connection { resolving[service] = nil }
        default: break
        }
    }
}
