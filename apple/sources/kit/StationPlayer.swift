extension PlayerModel {
    /// Tunes in on `output`, whose stream ending is the program ending: it
    /// asks the station what is on next.
    public func tune(_ tuner: StationTuner, on output: AVPlayerOutput) async {
        output.onEnd = { [weak self, weak tuner] in
            guard let self, let tuner else { return }
            Task { await self.programEnded(tuner) }
        }
        await tune(tuner)
    }
}
