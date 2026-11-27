import Foundation
import GRDB
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// The kit's replica, sync engine, action queue and models over HTTP
/// against a real server seeded by scripts/with-demo-server.py --fixtures,
/// with the plain generated client, as other devices, for the server's
/// truth. `make -C macos test-integration` runs it; without
/// RABBIT_EARS_UI_SERVER, _EMAIL and _PASSWORD it skips.
@MainActor
final class SyncEndToEndTests: XCTestCase {
    var server: SyncServer!
    private var directories: [URL] = []

    override func setUp() async throws {
        server = try await SyncServer.shared()
    }

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
    }

    /// A device of the household whose replica lives in a new directory, or in `directory`.
    func device(token: String? = nil, in directory: URL? = nil) throws -> SyncDevice {
        let directory = directory ?? FileManager.default.temporaryDirectory.appending(path: "sync-e2e-\(UUID())")
        directories.append(directory)
        return try SyncDevice(server: server.url, token: token ?? server.deviceToken, directory: directory)
    }

    // MARK: 1. Cold start

    func testAColdStartTakesASoundSnapshotOfTheFixtureSchema() async throws {
        let device = try device()
        let started = ContinuousClock.now
        try await device.engine.catchUp()
        let took = ContinuousClock.now - started
        XCTAssertEqual(device.sent.paths(), ["/sync/changes", "/sync/snapshot", "/sync/changes"])
        let file = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(at: device.directory, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasPrefix("replica-") && $0.pathExtension == "sqlite" })
        let bytes = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        print("sync-e2e: snapshot of \(bytes) bytes taken and adopted in \(took)")
        let check = try await device.replica.read { try String.fetchOne($0, sql: "PRAGMA quick_check") }
        XCTAssertEqual(check, "ok")

        let served = try await device.replica.read { try Self.schema($0) }
        let fixture = try await DatabaseQueue().write { db in
            try db.execute(sql: ReplicaSchema.v1)
            return try Self.schema(db)
        }
        XCTAssertEqual(served.keys.sorted(), fixture.keys.sorted(), "the projection's tables, views and indexes")
        for (name, sql) in fixture where served[name] != sql {
            XCTFail("\(name) is served as\n\(served[name] ?? "nothing")\nbut ReplicaSchema.v1 has\n\(sql)")
        }
    }

    /// Each table, view and index of the projection by name, its type and
    /// SQL as declared; the CLI's trailing comment on a view is dropped.
    /// The replica's own bookkeeping and search tables are left out.
    private nonisolated static func schema(_ db: Database) throws -> [String: String] {
        let local = ["sync_state", Replica.appliedTable]
        let rows = try Row.fetchAll(
            db, sql: "SELECT type, name, sql FROM main.sqlite_master WHERE name NOT LIKE 'fts\\_%' ESCAPE '\\'")
        var out: [String: String] = [:]
        for row in rows where !local.contains(row["name"]) {
            let sql = (row["sql"] as String? ?? "")
                .replacingOccurrences(of: #"\n/\* [^\n]* \*/$"#, with: "", options: .regularExpression)
            out[row["name"]] = "\(row["type"] as String): \(sql)"
        }
        return out
    }

    // MARK: 2. Parity

    func testEveryProfileReadsFromTheReplicaWhatTheServerAnswersIt() async throws {
        let device = try device()
        try await device.engine.catchUp()
        for profile in server.profiles where !profile.hiding {
            try await assertParity(device, profile)
        }
        // The adult hiding kids' content, set from another device.
        let adult = try XCTUnwrap(server.profiles.first { $0.hiding })
        _ = try await adult.rest.setProfilePreferences(
            path: .init(profileId: adult.id), body: .json(.init(hideKidsContent: true))
        ).ok
        let hidden: (any Error)?
        do {
            try await device.engine.catchUp()
            try await assertParity(device, adult)
            hidden = nil
        } catch {
            hidden = error
        }
        _ = try await adult.rest.setProfilePreferences(
            path: .init(profileId: adult.id), body: .json(.init(hideKidsContent: false))
        ).ok
        if let hidden { throw hidden }
    }

    private func assertParity(_ device: SyncDevice, _ profile: SyncServer.Profile) async throws {
        try await assertCatalog(device, profile)
        try await assertLists(device, profile)
        try await assertStations(device, profile)
        try await assertMusicAndYouTube(device, profile)
    }

    private func assertCatalog(_ device: SyncDevice, _ profile: SyncServer.Profile) async throws {
        let (rest, who) = (profile.rest, profile.name)
        let catalog = CatalogModel(
            client: rest, replica: device.replica, queue: device.queue, profileId: profile.id,
            hidingKids: profile.hiding)
        await catalog.load()
        var items: [Item] = []
        for kind in [ItemKind.movie, .show, .season, .episode] {
            items += try await Served.items(rest, kind)
            if profile.hiding { items += try await Served.items(rest, kind, kids: true) }
        }
        Parity.list(
            catalog.catalog.items.values.sorted { $0.id < $1.id }, items.sorted { $0.id < $1.id }, "\(who): catalog")
        let states = try await Served.watchStates(rest, profile.id)
        Parity.list(
            catalog.catalog.watch.values.sorted { $0.itemId < $1.itemId }, states.sorted { $0.itemId < $1.itemId },
            "\(who): watch states")
        for query in ["the", "light", "gear", "bench"] {
            let mine = await catalog.search(query)
            let theirs = try await rest.search(query: .init(q: query, limit: 20)).ok.body.json
            Parity.value(mine, Optional(theirs), "\(who): search for \(query)")
        }
    }

    private func assertLists(_ device: SyncDevice, _ profile: SyncServer.Profile) async throws {
        let (rest, who) = (profile.rest, profile.name)
        let playlists = PlaylistsModel(
            client: rest, replica: device.replica, queue: device.queue, profileId: profile.id,
            adult: profile.adult)
        await playlists.load()
        let served = try await rest.listPlaylists(path: .init(profileId: profile.id)).ok.body.json.items
        Parity.list(playlists.playlists, served, "\(who): playlists")
        for playlist in served {
            let entries = await playlists.entries(of: playlist.id)
            let theirs = try await rest.listPlaylistEntries(
                path: .init(profileId: profile.id, playlistId: playlist.id)
            ).ok.body.json.items
            Parity.list(entries ?? [], theirs, "\(who): entries of \(playlist.name)")
        }

        let collections = CollectionsModel(replica: device.replica, queue: device.queue, profileId: profile.id)
        await collections.load()
        let shelf = try await rest.listCollections().ok.body.json.items
        Parity.list(collections.collections, shelf, "\(who): collections")
        for collection in shelf {
            let movies = await collections.movies(of: collection.id)
            let theirs = try await rest.listCollectionMovies(path: .init(collectionId: collection.id))
                .ok.body.json.items
            Parity.list(movies ?? [], theirs, "\(who): movies of \(collection.name)")
        }
    }

    private func assertStations(_ device: SyncDevice, _ profile: SyncServer.Profile) async throws {
        let (rest, who) = (profile.rest, profile.name)
        let stations = StationsModel(
            client: rest, replica: device.replica, queue: device.queue, profileId: profile.id)
        let tuned = try await rest.listStations().ok.body.json.items
        let read = await stations.list() ?? []
        // The live position is each answer's own instant's.
        let unpositioned = { (stations: [Station]) in
            stations.map { station in
                var station = station
                station.onAir.positionMs = nil
                return station
            }
        }
        Parity.list(unpositioned(read), unpositioned(tuned), "\(who): stations")
        for (mine, theirs) in zip(read.map(\.onAir.positionMs), tuned.map(\.onAir.positionMs)) {
            XCTAssertEqual(mine == nil, theirs == nil, "\(who): on air")
            XCTAssertLessThan(abs((mine ?? 0) - (theirs ?? 0)), 5_000, "\(who): the live position")
        }
        let onNow = await stations.onNow()
        Parity.list(onNow.map(\.id), StationsModel.onNow(tuned).map(\.id), "\(who): stations on now")
        if profile.adult { XCTAssertFalse(onNow.isEmpty, "\(who): a continuous station is on now") }
        for station in tuned {
            let programs = try await Served.schedule(rest, station.id)
            Parity.list(await stations.schedule(of: station.id) ?? [], programs, "\(who): schedule of \(station.name)")
        }
    }

    private func assertMusicAndYouTube(_ device: SyncDevice, _ profile: SyncServer.Profile) async throws {
        let (rest, who) = (profile.rest, profile.name)
        let music = MusicModel(client: rest, replica: device.replica, profileId: profile.id)
        let albums = try await rest.listMusicAlbums(query: .init(limit: 100)).ok.body.json.items
        Parity.list(try await music.albums().items, albums, "\(who): albums")
        let artists = try await rest.listMusicArtists(query: .init(limit: 100)).ok.body.json.items
        Parity.list(try await music.artists().items, artists, "\(who): artists")
        let songs = try await rest.listMusicSongs(query: .init(limit: 100)).ok.body.json.items
        Parity.list(try await music.songs().items, songs, "\(who): songs")

        let youTube = YouTubeModel(client: rest, replica: device.replica, queue: device.queue, profileId: profile.id)
        let channels = try await rest.listYouTubeChannels().ok.body.json.items
        Parity.list(try await youTube.channels(), channels, "\(who): channels")
        let videos = try await rest.listYouTubeVideos(query: .init(limit: 100)).ok.body.json.items
        Parity.list(try await youTube.videos().items, videos, "\(who): videos")
    }

    // MARK: 3. Doorbell and diffs

    func testAnotherDevicesWritesRingTheDoorbellAndArriveAsDiffsOrASnapshot() async throws {
        let device = try device()
        try await device.engine.catchUp()
        let following = Task { await device.engine.follow() }
        defer { following.cancel() }
        try await until("the doorbell is held") { device.sent.paths().contains("/sync/version") }
        let adult = server.adult
        let movie = try server.movie("Wildflower")

        device.sent.clear()
        let started = ContinuousClock.now
        _ = try await adult.rest.putWatchState(
            path: .init(profileId: adult.id, itemId: movie),
            body: .json(.init(watched: false, positionMs: 61_000, at: Date()))
        ).ok
        try await until("the position arrives") { try await device.position(adult.id, movie) == 61_000 }
        print("sync-e2e: a write reached the replica by doorbell and diff in \(ContinuousClock.now - started)")
        XCTAssertTrue(device.sent.paths().contains("/sync/changes"))
        XCTAssertFalse(device.sent.paths().contains("/sync/snapshot"), "a diff, not a snapshot")

        device.sent.clear()
        _ = try await adult.rest.deleteWatchState(
            path: .init(profileId: adult.id, itemId: movie), query: .init(at: Date())
        ).noContent
        try await until("the tombstone arrives") { try await device.position(adult.id, movie) == nil }
        XCTAssertFalse(device.sent.paths().contains("/sync/snapshot"), "a tombstone, not a snapshot")

        device.sent.clear()
        let kid = try server.profile("Jamie")
        let playlist = try await adult.rest.createPlaylist(
            path: .init(profileId: adult.id), body: .json(.init(name: "Shared by bell", kind: .movies))
        ).created.body.json
        _ = try await adult.rest.createPlaylistShare(
            path: .init(profileId: adult.id, playlistId: playlist.id),
            body: .json(.init(profileId: kid.id, access: .read))
        ).created
        let jamie = PlaylistsModel(
            client: kid.rest, replica: device.replica, queue: device.queue, profileId: kid.id,
            adult: false)
        try await until("the share arrives") {
            await jamie.load()
            return jamie.playlists.contains { $0.id == playlist.id }
        }
        XCTAssertTrue(device.sent.paths().contains("/sync/snapshot"), "a share defines the household's scope")
        let theirs = try await kid.rest.listPlaylists(path: .init(profileId: kid.id)).ok.body.json.items
        Parity.list(jamie.playlists, theirs, "Jamie's playlists after the share")
    }

    // MARK: Creates

    func testAPlaylistMadeIsReadFromTheReplicaAsTheServerHasItOnceSentAndCaughtUp() async throws {
        let device = try device()
        try await device.engine.catchUp()
        let adult = server.adult
        let playlists = PlaylistsModel(
            client: adult.rest, replica: device.replica, queue: device.queue,
            profileId: adult.id)
        let created = await playlists.create(name: "Made online", kind: .tv)
        let made = try XCTUnwrap(created)
        XCTAssertTrue(playlists.playlists.contains(made), "in the replica on return")
        let flushed = await device.queue.flush()
        XCTAssertEqual(flushed, .done)
        try await device.engine.catchUp()
        await playlists.load()
        let served = try await adult.rest.getPlaylist(path: .init(profileId: adult.id, playlistId: made.id))
            .ok.body.json
        XCTAssertEqual(playlists.playlists.first { $0.id == made.id }, served)
    }

    // MARK: Support

    func until(_ what: String, _ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("timed out waiting until \(what)")
        throw CancellationError()
    }

    func within(_ limit: Duration, _ body: @escaping @Sendable () async -> Void) async throws {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                await body()
                return true
            }
            group.addTask {
                try await Task.sleep(for: limit)
                return false
            }
            let finished = try await group.next() ?? false
            group.cancelAll()
            XCTAssertTrue(finished, "did not end within \(limit)")
        }
    }
}
