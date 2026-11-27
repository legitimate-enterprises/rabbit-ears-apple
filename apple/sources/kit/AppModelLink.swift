import Foundation
import RabbitEarsAPI

/// Link a TV: signing a TV in with a code an adult approves on another device.
extension AppModel {
    public func requestLink(server: ServerEndpoint) async throws -> DeviceLink {
        let input = Components.Schemas.DeviceLinkInput(deviceName: deviceName, platform: platform)
        do {
            return try await secure(server).client(token: nil, transport: transport)
                .createDeviceLink(body: .json(input)).created.body.json
        } catch {
            throw AppError.from(error)
        }
    }

    /// One poll of a link; the answer that carries the token signs this
    /// device in, never asking which household. A link the server no
    /// longer knows, such as one handed over already, reads as expired.
    public func pollLink(_ link: DeviceLink, server: ServerEndpoint) async throws -> DeviceLinkStatus {
        let poll: Components.Schemas.DeviceLinkPoll
        do {
            poll = try await secure(server).client(token: nil, transport: transport)
                .pollDeviceLink(path: .init(linkId: link.id), query: .init(token: link.pollToken)).ok.body.json
        } catch {
            if APIError.from(error)?.status == 404 { return .expired }
            throw AppError.from(error)
        }
        if let result = poll.signIn { try await adopt(server, result) }
        return poll.status
    }
}
