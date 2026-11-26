extension PlayerModel {
    /// Starts the stream the request asks for, then brings it to the
    /// request's Watch together: after the stream loads, so a title paused
    /// for both opens paused, and a pause on the other side stops this one too.
    public func start(_ request: PlayRequest) async {
        await start(audioTrackId: request.audioTrackId, editionId: request.editionId, positionMs: request.positionMs)
        request.together?.attach(output)
    }
}
