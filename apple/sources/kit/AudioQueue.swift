import Foundation

public enum RepeatMode: Sendable, CaseIterable { case off, all, one }

/// The music queue: what has played, what plays now and Up next. It lives in
/// the client; the server sees one playback session per song.
public struct AudioQueue: Equatable, Sendable {
    public struct Entry: Identifiable, Equatable, Sendable {
        /// Unique within the queue, since a song may be queued twice.
        public let id: Int
        public let song: MusicSong
        /// Place in the unshuffled order.
        fileprivate var order: Int
    }

    public private(set) var entries: [Entry] = []
    public private(set) var index = 0
    public private(set) var shuffled = false
    public var repeatMode = RepeatMode.off
    /// What it plays from, as in "Playing from In Rainbows".
    public private(set) var source = ""
    /// The music playlist it plays from, sent with each song's playback.
    public private(set) var playlistId: Int64?
    /// Rises with every shuffle on or off, so a song's start can tell one was made meanwhile.
    private var shuffles = 0

    public init() {}

    /// Starts at `start`; shuffled, at a song picked at random, and the rest follow at random.
    public init(
        _ songs: [MusicSong], start: Int = 0, source: String, playlistId: Int64? = nil, shuffled: Bool = false
    ) {
        entries = songs.enumerated().map { Entry(id: $0.offset, song: $0.element, order: $0.offset) }
        index = shuffled ? songs.indices.randomElement() ?? 0 : songs.indices.contains(start) ? start : 0
        self.source = source
        self.playlistId = playlistId
        setShuffle(shuffled)
    }

    public var current: Entry? { entries.indices.contains(index) ? entries[index] : nil }
    public var upNext: [Entry] { entries.isEmpty ? [] : Array(entries[(index + 1)...]) }

    /// Shuffling keeps the current song and puts every other one in Up next,
    /// in `order`; turning it off puts every song back in its unshuffled
    /// place around the current one.
    public mutating func setShuffle(_ on: Bool, order: ([Entry]) -> [Entry] = { $0.shuffled() }) {
        shuffled = on
        shuffles += 1
        guard current != nil else { return }
        if on {
            let current = entries[index]
            entries = [current] + order(entries.filter { $0.id != current.id })
            index = 0
        } else if let id = current?.id {
            entries.sort { $0.order < $1.order }
            index = entries.firstIndex { $0.id == id } ?? 0
        }
    }

    /// Moves Up next entries, with offsets counted within Up next.
    public mutating func moveUpNext(fromOffsets source: IndexSet, toOffset destination: Int) {
        let upcoming = upNext
        guard let last = source.last, last < upcoming.count, destination <= upcoming.count else { return }
        var kept = upcoming.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        kept.insert(contentsOf: source.map { upcoming[$0] }, at: destination - source.count(in: 0..<destination))
        entries.replaceSubrange((index + 1)..., with: kept)
        if !shuffled { renumber() }
    }

    public mutating func remove(_ id: Entry.ID) {
        guard let at = entries.firstIndex(where: { $0.id == id }), at > index else { return }
        entries.remove(at: at)
    }

    public mutating func clearUpNext() {
        guard !entries.isEmpty else { return }
        entries.removeSubrange((index + 1)...)
    }

    /// Moves on; false at the end of a queue that does not repeat. Repeat
    /// one holds the song only when it ends on its own.
    @discardableResult
    public mutating func next(auto: Bool) -> Bool {
        guard current != nil else { return false }
        if auto && repeatMode == .one { return true }
        if index + 1 < entries.count {
            index += 1
            return true
        }
        guard repeatMode != .off else { return false }
        index = 0
        return true
    }

    /// Steps back, wrapping to the end only when the queue repeats.
    public mutating func previous() {
        if index > 0 {
            index -= 1
        } else if repeatMode != .off {
            index = max(0, entries.count - 1)
        }
    }

    /// Plays an Up next entry now; the ones before it are skipped into history.
    @discardableResult
    public mutating func jump(to id: Entry.ID) -> Bool {
        guard let at = entries.firstIndex(where: { $0.id == id }) else { return false }
        index = at
        return true
    }

    /// Moves to the song that has started from `candidate`, a copy of this
    /// queue; a shuffle on or off made while it started is made again around
    /// it, so the queue ends as if it had been playing.
    mutating func settle(on id: Entry.ID, from candidate: AudioQueue, order: ([Entry]) -> [Entry]) -> Bool {
        guard jump(to: id) else { return false }
        if shuffles != candidate.shuffles { setShuffle(shuffled, order: order) }
        return true
    }

    private mutating func renumber() {
        for position in entries.indices { entries[position].order = position }
    }
}
