import RabbitEarsAPI

/// The ways out of a video player in the cover: closing it, handing the
/// cover to what plays next, and, at a title's end, asking what follows.
@MainActor
public struct PlayerExit {
    let request: PlayRequest
    let model: PlayerModel
    let catalog: CatalogModel
    let browser: any VideoBrowser
    let close: () -> Void

    public init(
        request: PlayRequest, model: PlayerModel, catalog: CatalogModel, browser: any VideoBrowser,
        close: @escaping () -> Void
    ) {
        self.request = request
        self.model = model
        self.catalog = catalog
        self.browser = browser
        self.close = close
    }

    /// Closing leaves a Watch together in sync, which ends it for both
    /// members: no player would follow it.
    public func leave() {
        if let together = request.together, together.inSync { Task { await together.leave() } }
        finish()
        close()
    }

    /// What Up next plays, in the same cover.
    public func playNext(_ next: PlayRequest) {
        finish()
        browser.playing = next
    }

    /// At a title's end: what Up next offers, or nil once the player has
    /// closed for want of it. An answer that comes after the viewer moved on
    /// to another player does nothing to that player.
    public func ended(client: Client?, profile: Account?) async -> UpNextModel? {
        guard let client, let profile else {
            leave()
            return nil
        }
        let next = await UpNextModel.load(after: request, client: client, profile: profile)
        guard stillUp else { return nil }
        if let next { return next }
        leave()
        return nil
    }

    /// The cover keeps its id across Next episode and Up next; the title and
    /// the Watch together tell this player from the one replacing it.
    private var stillUp: Bool {
        guard let playing = browser.playing else { return false }
        return playing.id == request.id && playing.item.id == request.item.id && playing.together === request.together
    }

    /// Ends the server's session, then takes the watch state it left.
    public func finish() {
        let id = request.item.id
        Task {
            await model.stop()
            await catalog.refreshWatchState(id)
        }
    }
}
