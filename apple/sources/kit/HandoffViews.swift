import RabbitEarsAPI
import SwiftUI

/// Asks first when the title still plays on another device of the profile:
/// Move here, Watch together or Cancel. Otherwise, and for a request that
/// says where to start, the player shows at once. Move here is first, so it
/// has the focus when the alert opens.
public struct HandoffGate<Player: View>: View {
    let request: PlayRequest
    let client: Client
    let profileId: UID
    let browser: any VideoBrowser
    let close: () -> Void
    @ViewBuilder let player: () -> Player
    @State private var there: PlaybackSession?
    @State private var asking = false
    @State private var asked = false

    public init(
        request: PlayRequest, client: Client, profileId: UID, browser: any VideoBrowser,
        close: @escaping () -> Void, @ViewBuilder player: @escaping () -> Player
    ) {
        self.request = request
        self.client = client
        self.profileId = profileId
        self.browser = browser
        self.close = close
        self.player = player
    }

    /// What the player inside the cover is rebuilt for: another title or row, or the same one played another way.
    public static func identity(_ request: PlayRequest) -> String {
        "\(request.item.id)/\(request.queue?.index ?? 0)/\(request.positionMs ?? -1)/\(request.together != nil)"
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if asked { player() }
        }
        .alert(there.map(Handoff.title) ?? "", isPresented: $asking, presenting: there) { there in
            Button("Move here") { hand { try await Handoff.move(there, request, client: client) } }
            Button("Watch together") {
                hand { try await Handoff.together(there, request, client: client, profileId: profileId) }
            }
            Button("Cancel", role: .cancel, action: close)
        }
        .task {
            there = await Handoff.elsewhere(request, client: client)
            asking = there != nil
            asked = there == nil
        }
    }

    /// Plays what the answer makes of the request; a failed answer closes the player.
    private func hand(_ answer: @escaping () async throws -> PlayRequest) {
        Task {
            guard var next = try? await answer() else { return close() }
            // The cover keeps its identity; the player inside it is rebuilt.
            next.id = request.id
            browser.playing = next
        }
    }
}

/// Carries out what `PlayerHandoff` asks of an open player, saying where a
/// moved session went.
public struct PlayerLive: ViewModifier {
    let request: PlayRequest
    let model: PlayerModel
    let browser: any VideoBrowser
    let leave: () -> Void
    /// Ends the session of the player being replaced.
    let finish: () -> Void
    @Environment(AppModel.self) private var app
    @State private var handoff: PlayerHandoff?

    public init(
        request: PlayRequest, model: PlayerModel, browser: any VideoBrowser, leave: @escaping () -> Void,
        finish: @escaping () -> Void
    ) {
        self.request = request
        self.model = model
        self.browser = browser
        self.leave = leave
        self.finish = finish
    }

    public func body(content: Content) -> some View {
        content
            .task {
                guard let client = app.client, let profile = app.activeProfile else { return }
                let next = PlayerHandoff(
                    player: model, client: client, profileId: profile.id, itemId: request.item.id)
                handoff = next
                await next.follow(app.live)
            }
            .task { await request.together?.run() }
            // However the player goes away, its session and transcode slot go with it.
            .onDisappear { Task { await model.stop() } }
            .onChange(of: handoff?.movedTo) {
                guard let device = handoff?.movedTo else { return }
                app.live.say("Moved to \(device)")
                leave()
            }
            .onChange(of: handoff?.asked.map(ObjectIdentifier.init)) {
                guard let asked = handoff?.asked else { return }
                let position = model.output.positionMs
                finish()
                browser.playing = PlayRequest(
                    id: request.id, item: request.item, positionMs: position, together: asked)
            }
    }
}
