import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

extension Fixtures {
    static func song(
        _ id: UID, _ title: String, album: UID = 50, track: Int? = nil, disc: Int? = nil,
        durationMs: Int64 = 240_000
    ) -> String {
        var fields = [
            #""id":"\#(id)""#, #""libraryId":"\#(UID.n(3))""#, #""albumId":"\#(album)""#,
            #""albumTitle":"In Rainbows""#, #""albumArtistId":"\#(UID.n(40))""#, #""artistId":"\#(UID.n(40))""#,
            #""artistName":"Radiohead""#, #""title":"\#(title)""#,
            #""lossless":true"#, #""codec":"flac""#, #""durationMs":\#(durationMs)"#,
        ]
        if let track { fields.append(#""trackNumber":\#(track)"#) }
        if let disc { fields.append(#""discNumber":\#(disc)"#) }
        return "{\(fields.joined(separator: ","))}"
    }

    /// Songs 1 to `count` of In Rainbows, ids 1 to `count`.
    static func songs(_ count: Int) -> [MusicSong] {
        (1...count).map { decode(song(.n($0), "Song \($0)", track: $0), as: MusicSong.self) }
    }
}

final class AudioQueueTests: XCTestCase {
    private func ids(_ entries: [AudioQueue.Entry]) -> [UID] { entries.map(\.song.id) }

    func testStartsAtThePickedSongWithTheRestUpNext() {
        let queue = AudioQueue(Fixtures.songs(5), start: 2, source: "In Rainbows", playlistId: 8)
        XCTAssertEqual(queue.current?.song.id, 3)
        XCTAssertEqual(ids(queue.upNext), [4, 5])
        XCTAssertEqual(queue.source, "In Rainbows")
        XCTAssertEqual(queue.playlistId, 8)
    }

    func testNextStopsAtTheEndUnlessRepeating() {
        var queue = AudioQueue(Fixtures.songs(2), start: 1, source: "")
        XCTAssertFalse(queue.next(auto: true))
        XCTAssertEqual(queue.current?.song.id, 2)
        queue.repeatMode = .all
        XCTAssertTrue(queue.next(auto: true))
        XCTAssertEqual(queue.current?.song.id, 1)
    }

    func testRepeatOneHoldsOnlyWhenTheSongEndsOnItsOwn() {
        var queue = AudioQueue(Fixtures.songs(3), source: "")
        queue.repeatMode = .one
        XCTAssertTrue(queue.next(auto: true))
        XCTAssertEqual(queue.current?.song.id, 1)
        XCTAssertTrue(queue.next(auto: false))
        XCTAssertEqual(queue.current?.song.id, 2)
    }

    func testPreviousWrapsOnlyWhenRepeatingAll() {
        var queue = AudioQueue(Fixtures.songs(3), source: "")
        queue.previous()
        XCTAssertEqual(queue.current?.song.id, 1)
        queue.repeatMode = .all
        queue.previous()
        XCTAssertEqual(queue.current?.song.id, 3)
        queue.previous()
        XCTAssertEqual(queue.current?.song.id, 2)
    }

    func testShuffleKeepsTheCurrentSongAndOffRestoresAlbumOrder() {
        var queue = AudioQueue(Fixtures.songs(8), start: 3, source: "")
        queue.setShuffle(true)
        XCTAssertEqual(queue.current?.song.id, 4)
        XCTAssertEqual(queue.index, 0)
        XCTAssertEqual(Set(ids(queue.upNext)), [1, 2, 3, 5, 6, 7, 8])
        queue.next(auto: false)
        let playing = queue.current?.song.id
        queue.setShuffle(false)
        XCTAssertEqual(ids(queue.entries), [1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(queue.current?.song.id, playing)
    }

    func testShuffledStartPlaysAnySongFirst() {
        let queues = (0..<60).map { _ in AudioQueue(Fixtures.songs(6), source: "", shuffled: true) }
        XCTAssertTrue(queues.allSatisfy { $0.shuffled && $0.index == 0 && $0.upNext.count == 5 })
        XCTAssertGreaterThan(Set(queues.compactMap { $0.current?.song.id }).count, 1)
        XCTAssertNil(AudioQueue([], source: "", shuffled: true).current)
    }

    func testMovingUpNextSurvivesShuffleOnAndOff() {
        var queue = AudioQueue(Fixtures.songs(5), source: "")
        queue.moveUpNext(fromOffsets: [3], toOffset: 0)
        XCTAssertEqual(ids(queue.upNext), [5, 2, 3, 4])
        queue.moveUpNext(fromOffsets: [0, 1], toOffset: 4)
        XCTAssertEqual(ids(queue.upNext), [3, 4, 5, 2])
        queue.setShuffle(true)
        queue.setShuffle(false)
        XCTAssertEqual(ids(queue.entries), [1, 3, 4, 5, 2])
        queue.moveUpNext(fromOffsets: [9], toOffset: 0)
        XCTAssertEqual(ids(queue.upNext), [3, 4, 5, 2])
    }

    func testRemoveAndClearTouchOnlyUpNext() {
        var queue = AudioQueue(Fixtures.songs(5), start: 1, source: "")
        let history = queue.entries[0].id
        queue.remove(history)
        queue.remove(queue.current!.id)
        queue.remove(queue.upNext[1].id)
        XCTAssertEqual(ids(queue.entries), [1, 2, 3, 5])
        queue.clearUpNext()
        XCTAssertEqual(ids(queue.entries), [1, 2])
        XCTAssertEqual(queue.current?.song.id, 2)
    }

    func testJumpPlaysAnUpNextEntryAndADuplicateIsItsOwnEntry() {
        let songs = Fixtures.songs(3)
        var queue = AudioQueue(songs + [songs[0]], source: "")
        let duplicate = queue.upNext.last!.id
        XCTAssertTrue(queue.jump(to: duplicate))
        XCTAssertEqual(queue.index, 3)
        XCTAssertEqual(queue.current?.song.id, 1)
        XCTAssertFalse(queue.jump(to: 99))
    }

    func testAnEmptyQueueDoesNothing() {
        var queue = AudioQueue()
        XCTAssertNil(queue.current)
        XCTAssertEqual(queue.upNext, [])
        XCTAssertFalse(queue.next(auto: false))
        queue.setShuffle(true)
        queue.clearUpNext()
        queue.previous()
        XCTAssertNil(queue.current)
    }
}
