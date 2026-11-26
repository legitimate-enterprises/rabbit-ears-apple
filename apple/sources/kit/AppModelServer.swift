import Foundation
import RabbitEarsAPI

/// The server this device talks to: its address and what it is called.
extension AppModel {
    /// What the interface calls the place the person is in until a server is known.
    public static let productName = "Rabbit Ears"

    /// The name of the server this device signs in at, as it last said, from
    /// the store until it answers.
    public var serverName: String {
        // Reading `endpoint` makes a sign-in elsewhere redraw what shows this.
        name(of: endpoint?.baseURL ?? store.server)
    }

    /// The name of the server at an address typed or picked before signing in.
    public func serverName(at address: String) -> String { name(of: ServerEndpoint(userInput: address)?.baseURL) }

    public func serverName(at server: ServerEndpoint?) -> String { name(of: server?.baseURL) }

    /// Asks the server its name; no answer, or one without a name, keeps
    /// what is known. Only the stored server's name is kept between launches.
    public func learnName(_ server: ServerEndpoint) async {
        let health = try? await server.client(token: nil, transport: transport).getHealth().ok.body.json
        guard let name = health?.serverName, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        serverNames[server.baseURL] = name
        if server.baseURL == store.server { store.serverName = name }
    }

    /// Whether the signed-in server answers now, asked past every kept and
    /// downloaded answer, which stand in for it while it is gone.
    public func serverAnswers() async -> Bool {
        guard let endpoint else { return false }
        return (try? await endpoint.client(token: nil, transport: transport).getHealth().ok) != nil
    }

    public var lastServer: String { store.server?.absoluteString ?? "" }

    func parse(_ server: String) throws -> ServerEndpoint {
        guard let endpoint = ServerEndpoint(userInput: server) else { throw AppError.badServer }
        return try secure(endpoint)
    }

    /// Plain http is for a server on the local network; anywhere else the
    /// password and token would cross the internet in the clear.
    func secure(_ endpoint: ServerEndpoint) throws -> ServerEndpoint {
        guard endpoint.baseURL.scheme == "https" || endpoint.isLocalNetwork else { throw AppError.insecureServer }
        return endpoint
    }

    private func name(of server: URL?) -> String {
        guard let server else { return Self.productName }
        return serverNames[server] ?? (server == store.server ? store.serverName : nil) ?? Self.productName
    }
}
