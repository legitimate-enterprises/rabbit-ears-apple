import Foundation
import GRDB
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// SyncEndToEndTests of the action queue, a restart and a revoked device.
extension SyncEndToEndTests {
    // MARK: 4. The offline queue

    func testActionsQueuedOfflineShowAtOnceAndReachTheServerInOrder() async throws {
        let device = try device()
        let (adult, rest) = (server.adult, server.adult.rest)
        let (watched, played) = (try server.movie("After the Rain"), try server.movie("Golden Hour"))
        let show = try server.item("The Guild", .show)
        let (playlist, collection) = try await queuedLists()
        let (kept, dropped) = (try server.movie("Aurora"), try server.movie("Wildflower"))
        let playsBefore = try await Served.watchState(rest, adult.id, played)?.playCount ?? 0
        try await device.engine.catchUp()

        let queue = device.queue
        let playlists = PlaylistsModel(
            client: rest, replica: device.replica, queue: queue, engine: device.engine, profileId: adult.id)
        let collections = CollectionsModel(
            client: rest, replica: device.replica, queue: queue, engine: device.engine, profileId: adult.id)
        try await queue.putWatchState(true, item: watched, as: adult.id)
        try await queue.putWatchStates(true, items: [show], as: adult.id, in: device.replica)
        try await queue.setProfilePreferences(adult.id, color: nil, hideKidsContent: nil, autoplay: false, as: adult.id)
        let read = await playlists.entries(of: playlist)
        let entries = try XCTUnwrap(read)
        await playlists.move(entries[3], to: 1)
        await playlists.remove(entries[0])
        let added = await collections.add(movie: kept, to: collection)
        XCTAssertTrue(added)
        await collections.remove(movie: dropped, from: collection)
        try await queue.recordPlay(item: played, edition: nil, as: adult.id, at: Date())
        XCTAssertNil(playlists.error)
        XCTAssertNil(collections.error)

        let episodes = try await assertShownAtOnce(device, watched: watched, show: show, shelf: collection, kept: kept)
        let order = await playlists.entries(of: playlist)?.map(\.itemId)
        XCTAssertEqual(order, [entries[3], entries[1], entries[2]].map(\.itemId), "the playlist changed at once")
        let unsent = try await device.queued()
        XCTAssertEqual(unsent, 8, "nothing sent")

        let started = ContinuousClock.now
        let flushed = await queue.flush()
        XCTAssertEqual(flushed, .done)
        print("sync-e2e: 8 queued actions flushed in \(ContinuousClock.now - started)")
        try await device.engine.catchUp()

        let served = try await rest.listPlaylistEntries(path: .init(profileId: adult.id, playlistId: playlist))
            .ok.body.json.items
        Parity.list(await playlists.entries(of: playlist) ?? [], served, "the queued playlist")
        XCTAssertEqual(served.map(\.itemId), order, "the server's order is the queue's")
        let shelf = try await rest.listCollectionMovies(path: .init(collectionId: collection)).ok.body.json.items
        XCTAssertEqual(shelf.map(\.id), [kept])
        try await assertWatchStates(device, watched: [watched] + episodes)
        let playsAfter = try await Served.watchState(rest, adult.id, played)?.playCount
        XCTAssertEqual(playsAfter, playsBefore + 1, "one play")
        let me = try await rest.getProfile(path: .init(profileId: adult.id)).ok.body.json
        XCTAssertEqual(me.autoplay, false)
        let left = try await device.queued()
        XCTAssertEqual(left, 0)
        _ = try await rest.setProfilePreferences(path: .init(profileId: adult.id), body: .json(.init(autoplay: true)))
            .ok
    }

    /// The replica shows the watched movie and the show's episodes watched,
    /// autoplay off and the shelf holding only `kept`; answers the episodes.
    private func assertShownAtOnce(
        _ device: SyncDevice, watched: Int64, show: Int64, shelf: Int64, kept: Int64
    ) async throws -> [Int64] {
        let adult = server.adult.id
        let episodes = try await device.replica.read { db in
            try Int64.fetchAll(
                db, sql: "SELECT e.id FROM item e JOIN item s ON s.id = e.parent_id WHERE s.parent_id = ?",
                arguments: [show])
        }
        XCTAssertFalse(episodes.isEmpty)
        let local = try await device.replica.read { db in
            (
                try Bool.fetchAll(
                    db,
                    sql: "SELECT watched FROM watch_state WHERE account_id = ? "
                        + "AND item_id IN (SELECT value FROM json_each(?))",
                    arguments: [adult, "\([watched] + episodes)"]),
                try Bool.fetchOne(db, sql: "SELECT no_autoplay FROM account WHERE id = ?", arguments: [adult]),
                try Int64.fetchAll(
                    db, sql: "SELECT item_id FROM collection_movie WHERE collection_id = ?", arguments: [shelf])
            )
        }
        XCTAssertEqual(local.0, Array(repeating: true, count: episodes.count + 1), "watched at once")
        XCTAssertEqual(local.1, true, "autoplay off at once")
        XCTAssertEqual(local.2, [kept], "the shelf changed at once")
        return episodes
    }

    /// A playlist of four movies and a collection of one, made online.
    private func queuedLists() async throws -> (playlist: Int64, collection: Int64) {
        let (adult, rest) = (server.adult.id, server.adult.rest)
        let playlist = try await rest.createPlaylist(
            path: .init(profileId: adult), body: .json(.init(name: "Queued", kind: .movies))
        ).created.body.json
        for title in ["Aurora", "Blue Horizon", "Wildflower", "The Long Way Home"] {
            _ = try await rest.addPlaylistEntry(
                path: .init(profileId: adult, playlistId: playlist.id),
                body: .json(.init(itemId: try server.movie(title)))
            ).created
        }
        let collection = try await rest.createCollection(body: .json(.init(name: "Queued shelf"))).created.body.json
        _ = try await rest.addCollectionMovie(
            path: .init(collectionId: collection.id, itemId: try server.movie("Wildflower"))
        ).noContent
        return (playlist.id, collection.id)
    }

    /// The adult's watch states read are the server's, `watched` among them watched.
    private func assertWatchStates(_ device: SyncDevice, watched: [Int64]) async throws {
        let adult = server.adult
        let states = try await Served.watchStates(adult.rest, adult.id)
        let mine = try await device.replica.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM watch_state WHERE account_id = ?", arguments: [adult.id])
                .map(ReplicaRows.watchState)
        }
        Parity.list(mine.sorted { $0.itemId < $1.itemId }, states.sorted { $0.itemId < $1.itemId }, "watch states")
        for id in watched { XCTAssertEqual(states.first { $0.itemId == id }?.watched, true) }
    }

    // MARK: 5. A rejection heals

    func testAnActionTheServerRejectsComesBackAsTheServerHasIt() async throws {
        let device = try device()
        try await device.engine.catchUp()
        let kid = try server.profile("Jamie")
        let movie = try server.movie("The Long Way Home")
        let row = { @Sendable (db: Database) in
            try Row.fetchOne(db, sql: "SELECT * FROM item WHERE id = ?", arguments: [movie])?.description
        }
        let before = try await device.replica.read(row)
        try await device.queue.setKidsContent(true, for: movie, as: kid.id)
        let optimistic = try await device.replica.read { db in
            try Bool.fetchOne(db, sql: "SELECT kids_content FROM item WHERE id = ?", arguments: [movie])
        }
        XCTAssertEqual(optimistic, true)

        try await device.engine.catchUp()

        let after = try await device.replica.read(row)
        XCTAssertEqual(after, before, "the server's row again")
        XCTAssertEqual(device.notices.all, ["setKidsContent forbidden"])
        let served = try await server.adult.rest.getItem(path: .init(itemId: movie)).ok.body.json
        XCTAssertEqual(served.kidsContentOverride, nil)
    }

    // MARK: 6. Idempotency

    func testABatchSentTwiceChangesTheServerOnce() async throws {
        let device = try device()
        try await device.engine.catchUp()
        let adult = server.adult
        let movie = try server.movie("Blue Horizon")
        let before = try await Served.watchState(adult.rest, adult.id, movie)?.playCount ?? 0
        try await device.queue.recordPlay(item: movie, edition: nil, as: adult.id, at: Date())
        try await device.queue.putWatchState(false, positionMs: 12_000, item: movie, as: adult.id)
        // Each action's columns but seq, then seq; each touch's columns.
        let sent = try await device.replica.read { db in
            (
                try Row.fetchAll(
                    db,
                    sql: "SELECT uuid, operation_id, method, path, body, profile_id, at, seq "
                        + "FROM queue.action ORDER BY seq"
                ).map { Array($0.databaseValues) },
                try Row.fetchAll(db, sql: "SELECT action, table_name, key1, key2, key3 FROM queue.action_touch")
                    .map { Array($0.databaseValues) }
            )
        }
        let first = await device.queue.flush()
        XCTAssertEqual(first, .done)
        let once = try await Served.watchState(adult.rest, adult.id, movie)
        XCTAssertEqual(once?.playCount, before + 1)

        try await device.replica.write { db in
            for action in sent.0 {
                try db.execute(
                    sql: "INSERT INTO queue.action(uuid, operation_id, method, path, body, profile_id, at) "
                        + "VALUES (?, ?, ?, ?, ?, ?, ?)",
                    arguments: StatementArguments(action.dropLast()))
                let seq = db.lastInsertedRowID.databaseValue
                for touch in sent.1 where touch[0] == action.last {
                    try db.execute(
                        sql: "INSERT INTO queue.action_touch VALUES (?, ?, ?, ?, ?)",
                        arguments: StatementArguments([seq] + touch.dropFirst()))
                }
            }
        }
        let second = await device.queue.flush()
        XCTAssertEqual(second, .done)
        let twice = try await Served.watchState(adult.rest, adult.id, movie)
        XCTAssertEqual(twice, once, "answered as before")
        XCTAssertEqual(device.notices.all, [])
        try await device.engine.catchUp()
        let mine = try await device.replica.read { db in
            try Row.fetchOne(
                db, sql: "SELECT * FROM watch_state WHERE account_id = ? AND item_id = ?",
                arguments: [adult.id, movie]
            ).map(ReplicaRows.watchState)
        }
        XCTAssertEqual(mine, once)
    }

    // MARK: 7. Restart

    func testAReopenedReplicaResumesByDiffAndKeepsWhatIsQueuedAcrossASnapshot() async throws {
        let adult = server.adult
        let movie = try server.movie("Aurora")
        let directory: URL
        do {
            let first = try device()
            directory = first.directory
            try await first.engine.catchUp()
            try await first.queue.putWatchState(false, positionMs: 7_000, item: movie, as: adult.id)
        }
        _ = try await adult.rest.putWatchState(
            path: .init(profileId: adult.id, itemId: try server.movie("Golden Hour")),
            body: .json(.init(watched: false, positionMs: 31_000, at: Date()))
        ).ok

        let again = try device(in: directory)
        let queued = try await again.queued()
        XCTAssertEqual(queued, 1, "the unsent action outlived the restart")
        let started = ContinuousClock.now
        try await again.engine.catchUp()
        print("sync-e2e: a reopened replica caught up in \(ContinuousClock.now - started)")
        XCTAssertEqual(again.sent.paths(), ["/sync/actions", "/sync/changes"], "the queue, then a diff")
        let resumed = try await Served.watchState(adult.rest, adult.id, movie)?.positionMs
        XCTAssertEqual(resumed, 7_000)

        try await again.queue.putWatchState(false, positionMs: 8_000, item: movie, as: adult.id)
        let snapshot = again.replica.partFile()
        let body = try await adult.rest.getSyncSnapshot(query: .init(schema: 1)).ok.body.applicationVnd_sqlite3
        try await Data(collecting: body, upTo: 64 << 20).write(to: snapshot)
        try again.replica.adopt(snapshot, prepare: ReplicaSearch.build)
        let kept = try await again.queued()
        XCTAssertEqual(kept, 1, "the unsent action outlived a snapshot")
        let sentAfterSwap = await again.queue.flush()
        XCTAssertEqual(sentAfterSwap, .done)
        let swapped = try await Served.watchState(adult.rest, adult.id, movie)?.positionMs
        XCTAssertEqual(swapped, 8_000)
    }

    // MARK: 8. Auth

    func testARevokedDeviceSignsOutInsteadOfRetrying() async throws {
        let token = try await server.signIn("revoked")
        let device = try device(token: token)
        try await device.engine.catchUp()
        _ = try await Client.connect(to: server.url, token: token).signOut().noContent

        let following = Task { await device.engine.follow() }
        try await within(.seconds(20)) { await following.value }
        XCTAssertEqual(device.signOuts.all, ["signOut"])
    }
}
