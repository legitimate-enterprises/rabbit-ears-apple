import Foundation
import GRDB
import HTTPTypes
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// Writes a few bytes where each fetch should land, or fails as told.
final class FakeDownloader: Downloader, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [URLRequest] = []
    private var failing: DownloadFailure?
    private var resumedWith: [Data?] = []
    private var cancelled = 0
    private var observer: (@Sendable (@escaping @Sendable (Double) -> Void) async -> Void)?

    var requests: [URLRequest] { lock.withLock { log } }
    var cancels: Int { lock.withLock { cancelled } }
    var resumes: [Data?] { lock.withLock { resumedWith } }
    var failure: DownloadFailure? {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }
    /// Awaited as each fetch starts, with its progress, before the fetch lands or fails.
    var onFetch: (@Sendable (@escaping @Sendable (Double) -> Void) async -> Void)? {
        get { lock.withLock { observer } }
        set { lock.withLock { observer = newValue } }
    }

    func fetch(
        _ request: URLRequest, to destination: URL, resumeData: Data?, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let (failure, observer) = lock.withLock {
            log.append(request)
            resumedWith.append(resumeData)
            return (failing, self.observer)
        }
        await observer?(progress)
        if let failure { throw failure }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("media".utf8).write(to: destination)
        progress(1)
    }

    func cancelAll() { lock.withLock { cancelled += 1 } }
}

/// What the store reads of the device, changed by a test; observable as
/// the apps' capability sources are.
@MainActor
@Observable
final class FactsBox {
    var path = PathFacts()
    var now = Date(timeIntervalSince1970: 1_800_000_000)

    var facts: DeviceFacts {
        DeviceFacts(
            hardwareVideoCodecs: ["h264"], hdrPlayback: false, audioDecoders: [], playableTypes: ["public.mpeg-4"],
            screen: ScreenFacts(width: 1920, height: 1080, refreshRate: 60, edrHeadroom: 1),
            route: RouteFacts(channels: 2), path: path)
    }
}

extension Fixtures {
    static func downloadTitle(
        _ id: UID, _ kind: String, library: UID = 1, size: Int64 = 100, watched: Bool = false,
        position: Int64 = 0, runtime: Int64 = 3_000_000, available: Bool = true
    ) -> String {
        #"{"itemId":"\#(id)","kind":"\#(kind)","libraryId":"\#(library)","available":\#(available),"#
            + #""watched":\#(watched),"positionMs":\#(position),"sizeBytes":\#(size),"runtimeMs":\#(runtime),"#
            + #""quality":"original","verdict":"direct_play","container":"mp4","estimated":false}"#
    }

    static func download(
        _ id: UID, item: UID, profile: UID = 1, status: String = "ready", size: Int64 = 100
    ) -> String {
        #"{"id":"\#(id)","profileId":"\#(profile)","itemId":"\#(item)","mediaFileId":"\#(UID.n(1))","#
            + #""quality":"original","#
            + #""status":"\#(status)","verdict":"direct_play","container":"mp4","sizeBytes":\#(size),"#
            + #""estimated":false,"#
            + #""progress":1,"url":"/api/v2/downloads/\#(id)/file","#
            + #""subtitles":[{"trackId":"\#(UID.n(4))","isForced":true,"#
            + #""url":"/api/v2/downloads/\#(id)/subtitles/\#(UID.n(4)).vtt"}],"#
            + #""createdAt":"2026-01-01T00:00:00Z","modifiedAt":"2026-01-01T00:00:00Z"}"#
    }
}

/// What a store's local plays sent through its seam to the action queue;
/// with `replica`, each is also written there as the queued action's local
/// change would be, so the catalog reads it.
@MainActor
final class PlayLog {
    enum Call: Equatable {
        case progress(profile: UID, item: UID, edition: UID?, positionMs: Int64, watched: Bool, at: Date)
        case finished(profile: UID, item: UID, edition: UID?, at: Date)
    }

    var calls: [Call] = []
    var replica: Replica?

    var plays: LocalPlays {
        LocalPlays(
            progress: { [weak self] profile, item, edition, position, watched, at in
                self?.calls.append(
                    .progress(
                        profile: profile, item: item, edition: edition, positionMs: position, watched: watched, at: at))
                _ = try? await self?.replica?.write { db in
                    try db.execute(
                        sql: """
                            INSERT INTO watch_state (account_id, item_id, position_ms, watched, play_count,
                                last_played_at, changed_at, edition_id) VALUES (?1, ?2, ?3, ?4, 0, ?5, ?5, ?6)
                            ON CONFLICT DO UPDATE SET position_ms = ?3, watched = ?4, last_played_at = ?5,
                                changed_at = ?5, edition_id = ?6
                            """,
                        arguments: [profile, item, position, watched, Int64(at.timeIntervalSince1970 * 1000), edition])
                }
            },
            finished: { [weak self] profile, item, edition, at in
                self?.calls.append(.finished(profile: profile, item: item, edition: edition, at: at))
                _ = try? await self?.replica?.write { db in
                    try db.execute(
                        sql: """
                            INSERT INTO watch_state (account_id, item_id, position_ms, watched, play_count,
                                last_played_at, changed_at, edition_id) VALUES (?1, ?2, 0, 1, 1, ?3, ?3, ?4)
                            ON CONFLICT DO UPDATE SET position_ms = 0, watched = 1, play_count = play_count + 1,
                                last_played_at = ?3, changed_at = ?3, edition_id = ?4
                            """, arguments: [profile, item, Int64(at.timeIntervalSince1970 * 1000), edition])
                }
            })
    }
}

/// A store in a folder of its own, signed in to a server that resolves
/// each target to the titles a test sets and answers every download ready,
/// with a replica of profile 1 and a log of its local plays.
@MainActor
final class DownloadHarness {
    let transport = RoutingTransport()
    let downloader = FakeDownloader()
    let box = FactsBox()
    let directory = FileManager.default.temporaryDirectory.appending(path: "Application Support \(UUID().uuidString)")
    let endpoint = ServerEndpoint(baseURL: URL(string: "http://rabbit.local:8477")!)
    let store: DownloadStore
    let client: Client
    let server = FakeDownloadServer()
    let fixture = ReplicaFixture()
    let replica: Replica
    let plays = PlayLog()
    /// By target key, as `item/10`: the titles resolving it answers.
    var resolves: [String: [String]] {
        get { server.locked { $0.resolves } }
        set { server.locked { $0.resolves = newValue } }
    }
    /// Titles sync says the profile may no longer keep.
    var removing: Set<UID> {
        get { server.locked { $0.removing } }
        set { server.locked { $0.removing = newValue } }
    }
    /// By item: the error a batch claim answers for it.
    var refusing: [UID: String] {
        get { server.locked { $0.refusing } }
        set { server.locked { $0.refusing = newValue } }
    }
    /// Answers by "METHOD /path", consulted before the download routes.
    var objects: [String: String] {
        get { server.locked { $0.objects } }
        set { server.locked { $0.objects = newValue } }
    }

    init() {
        let box = box
        store = DownloadStore(
            directory: directory, downloader: downloader, facts: { box.facts }, pollInterval: .milliseconds(1),
            now: { MainActor.assumeIsolated { box.now } })
        client = endpoint.client(token: "tok-1", transport: transport, offline: store)
        // swiftlint:disable:next force_try
        replica = try! fixture.v1 { db in try db.account(1, "Avery") }
        store.connect(client: client, endpoint: endpoint, token: "tok-1", replica: replica, plays: plays.plays)
        transport.respond = { [server] in server.answer($0) }
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
        fixture.remove()
    }

    /// The Me the app keeps for the server, as it does after the server answers `json`.
    func keep(me json: String) throws {
        let me = Fixtures.decode(json, as: Components.Schemas.Me.self)
        replica.keep(try DownloadStore.encoder.encode(me), as: AppModel.keptMe(endpoint))
    }

    /// A store of the art the replica names for profile 1, through the harness's client, as AppModel makes one.
    func artwork(kept: URLCache? = nil) -> ArtworkStore {
        ArtworkStore(client: client, kept: kept) { [replica] key in
            (try? await replica.read { try key.address(for: 1, $0) }) ?? nil
        }
    }

    /// The server is gone: every call fails as with no network.
    func goOffline() { transport.failure = URLError(.notConnectedToInternet) }

    func goOnline() {
        transport.failure = nil
        store.reached()
    }

    func exists(_ itemId: UID) -> Bool {
        store.titles[itemId].flatMap(store.file(of:)).map {
            FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
        }
            ?? false
    }

    /// Asks for a target and fetches what it covers.
    @discardableResult
    func download(_ target: DownloadTarget, profile: UID = 1) async throws -> DownloadPlan? {
        let plan = try await store.request(target, quality: .original, profile: profile)
        await settle()
        return plan
    }

    /// Waits out the pump and transfers a request or setting started in a task of its own, then pumps once more.
    func settle() async {
        for _ in 0..<500 where store.pumping || !store.transfers.isEmpty {
            try? await Task.sleep(for: .milliseconds(2))
        }
        await store.pump()
    }
}

/// The download routes a harness answers, read off the main actor as requests arrive.
final class FakeDownloadServer: @unchecked Sendable {
    struct State {
        var resolves: [String: [String]] = [:]
        var removing: Set<UID> = []
        var objects: [String: String] = [:]
        /// By item: the error a batch claim answers for it.
        var refusing: [UID: String] = [:]

        /// The file is the size resolving it predicted.
        func size(_ item: UID) -> Int64 {
            resolves.values.joined().lazy
                .compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
                .first { $0["itemId"] as? String == item.description }?["sizeBytes"] as? Int64 ?? 100
        }
    }

    private let lock = NSLock()
    private var state = State()

    func locked<T>(_ body: (inout State) -> T) -> T { lock.withLock { body(&state) } }

    func answer(_ sent: RoutingTransport.Sent) -> (HTTPResponse.Status, String)? {
        let state = locked { $0 }
        if let object = state.objects["\(sent.method.rawValue) \(sent.path)"] { return (.ok, object) }
        let json = (try? JSONSerialization.jsonObject(with: Data(sent.body.utf8))) as? [String: Any]
        switch (sent.method, sent.path) {
        case (.post, let path) where path.hasSuffix("/downloads/resolve"):
            let target = (json?["targets"] as? [[String: Any]])?.first ?? [:]
            let key =
                target["playlistId"].map { "playlist/\($0)" } ?? target["collectionId"].map { "collection/\($0)" }
                ?? "item/\(target["itemId"] ?? "")"
            guard let titles = state.resolves[key] else { return (.notFound, Fixtures.error("not_found")) }
            return (.ok, #"{"titles":[\#(titles.joined(separator: ","))],"sizeBytes":0}"#)
        case (.post, let path) where path.hasSuffix("/downloads/sync"):
            let ids = ((json?["itemIds"] as? [String]) ?? []).compactMap(UID.init)
            let keep = ids.filter { !state.removing.contains($0) }.map { #""\#($0)""# }.joined(separator: ",")
            let remove = ids.filter(state.removing.contains).map { #""\#($0)""# }.joined(separator: ",")
            return (.ok, #"{"keep":[\#(keep)],"remove":[\#(remove)]}"#)
        case (.post, let path) where path.hasSuffix("/downloads/batch"):
            return (.ok, batch(path, json, state))
        case (.get, let path) where path.contains("/downloads/"):
            guard let id = path.split(separator: "/").last.flatMap({ UID(String($0)) }) else { return nil }
            let profile = UID(String(path.split(separator: "/")[1])) ?? 1
            return (.ok, Fixtures.download(id, item: id, profile: profile, size: state.size(id)))
        case (.delete, _): return (.noContent, "")
        default: return nil
        }
    }

    private func batch(_ path: String, _ json: [String: Any]?, _ state: State) -> String {
        let profile = UID(String(path.split(separator: "/")[1])) ?? 1
        let titles = (json?["titles"] as? [[String: Any]]) ?? []
        let results = titles.compactMap { title -> String? in
            guard let item = (title["itemId"] as? String).flatMap(UID.init) else { return nil }
            if let error = state.refusing[item] { return #"{"itemId":"\#(item)","error":\#(error)}"# }
            let download = Fixtures.download(item, item: item, profile: profile, size: state.size(item))
            return #"{"itemId":"\#(item)","download":\#(download)}"#
        }
        return #"{"results":[\#(results.joined(separator: ","))]}"#
    }
}

extension DownloadTarget {
    static func show(_ id: UID) -> DownloadTarget { .init(scope: .item, id: id, name: "Show \(id)", standing: true) }
    static func title(_ id: UID) -> DownloadTarget {
        .init(scope: .item, id: id, name: "Title \(id)", standing: false)
    }
    static func album(_ id: UID) -> DownloadTarget {
        .init(scope: .item, id: id, name: "Album \(id)", standing: true, music: true)
    }
    static func playlist(_ id: UID) -> DownloadTarget {
        .init(scope: .playlist, id: id, name: "Playlist \(id)", standing: true)
    }
}
