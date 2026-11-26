import Foundation
import Observation
import RabbitEarsAPI

/// Everything the device keeps for offline play, written to one file
/// beside the media it describes.
struct DownloadLedger: Codable, Sendable {
    var server: URL?
    var wifiOnly = true
    var allowanceBytes: Int64 = 20 << 30
    var settings: [Int64: DownloadSettings] = [:]
    var requests: [DownloadRequest] = []
    var titles: [Int64: StoredTitle] = [:]
    var shelf = OfflineShelf()
    /// By profile and item: changes not yet on the server.
    var unsynced: [Int64: [Int64: LocalWatch]] = [:]
}

/// The device's downloads: each profile's requests, the one stored copy of
/// each title they cover, reference counted across requests and profiles,
/// and the metadata and artwork that let the app browse them offline.
@MainActor
@Observable
public final class DownloadStore {
    /// More titles than this, or a bigger share of the allowance, asks first.
    public static let bigCount = 50
    public static let bigShare = 0.2

    var ledger = DownloadLedger()
    let directory: URL
    let downloader: any Downloader
    let now: () -> Date
    /// What this device plays, for the snapshot each resolve and claim sends.
    let facts: @MainActor () -> DeviceFacts
    /// The first wait before a pump the server stopped goes again.
    let pollInterval: Duration
    var link: Link?
    var pumping = false
    /// A pump was asked for while one claimed, so another follows it.
    var pumpAgain = false
    /// By title: each transfer in flight; true unless the server stopped it.
    var transfers: [Int64: Task<Bool, Never>] = [:]
    var watchingPath = false
    var waitingToPump = false
    /// Pumps stopped in a row, which lengthen the wait before the next.
    var stops = 0
    /// The last time a call found no server, which offline answers trust for a while.
    var unreachableSince: Date?
    var sessions: [Int64: LocalSession] = [:]
    var nextSession: Int64 = 0

    /// How the store reaches the server while signed in.
    struct Link {
        let client: Client
        let endpoint: ServerEndpoint
        let token: String
    }

    public init(
        directory: URL = DownloadStore.defaultDirectory, downloader: any Downloader,
        facts: @escaping @MainActor () -> DeviceFacts, pollInterval: Duration = .seconds(3),
        now: @escaping () -> Date = Date.init
    ) {
        self.directory = directory
        self.facts = facts
        self.downloader = downloader
        self.pollInterval = pollInterval
        self.now = now
        if let data = try? Data(contentsOf: ledgerFile),
            let saved = try? Self.decoder.decode(
                DownloadLedger.self, from: data)
        {
            ledger = saved
        }
        // No one awaits the fetch a title was in once its process ends; the next keeps a file that
        // landed meanwhile, or resumes from the resume data.
        for (id, title) in ledger.titles {
            switch title.state {
            case .preparing, .downloading: ledger.titles[id]?.state = .pending
            default: break
            }
        }
    }

    /// In the app's own container, which backups leave out.
    public static var defaultDirectory: URL { URL.applicationSupportDirectory.appending(path: "Downloads") }

    var ledgerFile: URL { directory.appending(path: "ledger.json") }
    var media: URL { directory.appending(path: "media") }
    var art: URL { directory.appending(path: "art") }

    // MARK: Signing in and out

    /// Signed in on `endpoint`: a different server's downloads go first.
    public func connect(client: Client, endpoint: ServerEndpoint, token: String) {
        if let server = ledger.server, server != endpoint.baseURL { wipe() }
        ledger.server = endpoint.baseURL
        link = Link(client: client, endpoint: endpoint, token: token)
        save()
    }

    /// Signed out or revoked: every download and what describes it goes.
    public func wipe() {
        link = nil
        sessions = [:]
        downloader.cancelAll()
        try? FileManager.default.removeItem(at: directory)
        ledger = DownloadLedger(wifiOnly: ledger.wifiOnly, allowanceBytes: ledger.allowanceBytes)
        save()
    }

    /// A profile the server no longer knows: its requests go, and what only they held.
    public func wipe(profile: Int64) {
        ledger.requests.removeAll { $0.profileId == profile }
        ledger.settings[profile] = nil
        ledger.unsynced[profile] = nil
        ledger.shelf.watch[profile] = nil
        collect()
    }

    // MARK: Reading

    public var requests: [DownloadRequest] { ledger.requests }
    public var titles: [Int64: StoredTitle] { ledger.titles }
    public var libraries: [Library] { ledger.shelf.libraries }
    /// Whether this server has anything kept here, so the app may open without it.
    public var hasDownloads: Bool { !ledger.requests.isEmpty }

    public func requests(for profile: Int64) -> [DownloadRequest] {
        ledger.requests.filter { $0.profileId == profile }
    }

    public func request(_ target: DownloadTarget, profile: Int64) -> DownloadRequest? {
        ledger.requests.first { $0.profileId == profile && $0.target == target }
    }

    /// The title's stored copy when the profile's requests cover it and it is all on the device.
    public func onDevice(_ itemId: Int64, profile: Int64) -> StoredTitle? {
        guard let title = ledger.titles[itemId], title.state == .onDevice,
            requests(for: profile).contains(where: { $0.titles.contains(itemId) })
        else { return nil }
        return title
    }

    /// For the artwork badge: a title on the device, or the profile's request
    /// for exactly this container whose every title is.
    public func badged(_ id: Int64, scope: DownloadTarget.Scope = .item, profile: Int64) -> Bool {
        if scope == .item, onDevice(id, profile: profile) != nil { return true }
        guard let request = requests(for: profile).first(where: { $0.target.scope == scope && $0.target.id == id }),
            !request.titles.isEmpty
        else { return false }
        return request.titles.allSatisfy { ledger.titles[$0]?.state == .onDevice }
    }

    public func file(of title: StoredTitle) -> URL? { title.file.map { media.appending(path: $0) } }

    public var usedBytes: Int64 {
        ledger.titles.values.filter(\.state.holdsSpace).reduce(0) { $0 + $1.sizeBytes }
    }

    /// The bytes a request's titles take, shared ones included.
    public func sizeBytes(_ request: DownloadRequest) -> Int64 {
        request.titles.reduce(0) { $0 + (ledger.titles[$1]?.sizeBytes ?? 0) }
    }

    /// The request's state as one line: on the device, or how far along and what holds it up.
    public func state(_ request: DownloadRequest) -> String {
        let states = request.titles.compactMap { ledger.titles[$0]?.state }
        let done = states.filter { $0 == .onDevice }.count
        if done == states.count { return DownloadState.onDevice.label }
        let blocker = states.first { $0 != .onDevice && $0 != .pending } ?? .pending
        return "\(done) of \(states.count) · \(blocker.label)"
    }

    // MARK: Preferences

    public func settings(_ profile: Int64) -> DownloadSettings { ledger.settings[profile] ?? DownloadSettings() }

    public func setSettings(_ settings: DownloadSettings, for profile: Int64) {
        let before = self.settings(profile)
        ledger.settings[profile] = settings
        if settings.keep != before.keep { applyKeepPolicy(profile) }
        save()
    }

    public var wifiOnly: Bool {
        get { ledger.wifiOnly }
        set {
            ledger.wifiOnly = newValue
            save()
            Task { await pump() }
        }
    }

    public var allowanceBytes: Int64 {
        get { ledger.allowanceBytes }
        set {
            ledger.allowanceBytes = max(0, newValue)
            for (id, title) in ledger.titles where title.state == .waitingForSpace {
                ledger.titles[id]?.state = .pending
            }
            save()
            Task { await pump() }
        }
    }

    // MARK: Requests

    /// Whether the plan is big enough to ask about, unless the profile said not to.
    public func needsConfirmation(_ plan: DownloadPlan) -> Bool {
        guard settings(plan.profileId).confirmBig else { return false }
        return plan.count > Self.bigCount
            || Double(plan.sizeBytes) > Self.bigShare * Double(ledger.allowanceBytes)
    }

    /// Keeps a planned request; Don't ask again stops the profile's big-request question here.
    public func keep(_ plan: DownloadPlan, dontAskAgain: Bool = false) {
        if dontAskAgain {
            var settings = settings(plan.profileId)
            settings.confirmBig = false
            ledger.settings[plan.profileId] = settings
        }
        apply(plan.titles, to: plan.target, profile: plan.profileId, quality: plan.quality)
        Task {
            if let link { await describe(plan.target, profile: plan.profileId, link) }
            await pump()
        }
    }

    /// Takes a request away; titles no other request holds leave the device.
    public func remove(_ target: DownloadTarget, profile: Int64) {
        ledger.requests.removeAll { $0.profileId == profile && $0.target == target }
        collect()
    }

    public func retry(_ itemId: Int64) {
        guard case .failed = ledger.titles[itemId]?.state else { return }
        ledger.titles[itemId]?.state = .pending
        save()
        Task { await pump() }
    }

    /// Sets what a request covers from a resolution: everything available,
    /// but in a standing request not the watched titles of a library that
    /// removes them. New titles wait to download; dropped ones go when
    /// nothing else holds them.
    func apply(_ resolved: [DownloadTitle], to target: DownloadTarget, profile: Int64, quality: DownloadQuality) {
        let settings = settings(profile)
        let covered = resolved.filter { title in
            title.available
                && !(target.standing && title.watched && !settings.keeps(library: title.libraryId, kind: title.kind))
        }
        let ids = covered.map(\.itemId)
        if let index = ledger.requests.firstIndex(where: { $0.profileId == profile && $0.target == target }) {
            ledger.requests[index].titles = ids
        } else {
            ledger.requests.append(
                DownloadRequest(profileId: profile, target: target, quality: quality, titles: ids, createdAt: now()))
        }
        for title in covered where ledger.titles[title.itemId] == nil {
            ledger.titles[title.itemId] = StoredTitle(title, quality: quality)
        }
        for title in resolved where title.kind != .song && ledger.unsynced[profile]?[title.itemId] == nil {
            remember(watched: title.watched, positionMs: title.positionMs, itemId: title.itemId, profile: profile)
        }
        collect()
    }

    /// Drops from the profile's requests what the server says it may no longer keep.
    func drop(_ itemIds: Set<Int64>, profile: Int64) {
        guard !itemIds.isEmpty else { return }
        for index in ledger.requests.indices where ledger.requests[index].profileId == profile {
            ledger.requests[index].titles.removeAll { itemIds.contains($0) }
        }
        collect()
    }

    /// Takes watched titles out of the profile's standing requests where their library removes them.
    func applyKeepPolicy(_ profile: Int64) {
        let settings = settings(profile)
        let watch = ledger.shelf.watch[profile] ?? [:]
        let titles = ledger.titles
        for index in ledger.requests.indices
        where ledger.requests[index].profileId == profile && ledger.requests[index].target.standing {
            ledger.requests[index].titles.removeAll { id in
                guard let title = titles[id], watch[id]?.watched == true else { return false }
                return !settings.keeps(library: title.libraryId, kind: title.kind)
            }
        }
        collect()
    }

    /// Deletes every stored title no request holds, with its files and
    /// metadata, and any file in media/ no stored title holds; its transfer
    /// stops and the server lets its claim go.
    func collect() {
        let held = Set(ledger.requests.flatMap(\.titles))
        for (id, title) in ledger.titles where !held.contains(id) {
            transfers[id]?.cancel()
            if let claim = title.claim, let link { Task { _ = await release(claim, link) } }
            ledger.titles[id] = nil
        }
        // Each media file's name starts with its title's id, so one that
        // landed before its title names it is kept.
        let files = (try? FileManager.default.contentsOfDirectory(atPath: media.path(percentEncoded: false))) ?? []
        for name in files where ledger.titles[Int64(name.prefix(while: \.isNumber)) ?? -1] == nil {
            try? FileManager.default.removeItem(at: media.appending(path: name))
        }
        let kept = ledger.shelf.prune(
            titles: held, collections: Set(ledger.requests.filter { $0.target.scope == .collection }.map(\.target.id)),
            playlists: Set(ledger.requests.filter { $0.target.scope == .playlist }.map(\.target.id)))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: art.path(percentEncoded: false))) ?? []
        for name in names where !kept.contains(name) {
            try? FileManager.default.removeItem(at: art.appending(path: name))
        }
        save()
    }

    // MARK: Watch state

    /// A change made on this device, kept with when it happened until the server has it.
    public func record(watched: Bool, positionMs: Int64, editionId: Int64? = nil, itemId: Int64, profile: Int64) {
        ledger.unsynced[profile, default: [:]][itemId] = LocalWatch(
            watched: watched, positionMs: positionMs, editionId: editionId, at: now())
        remember(watched: watched, positionMs: positionMs, editionId: editionId, itemId: itemId, profile: profile)
        if watched { applyKeepPolicy(profile) } else { save() }
    }

    func remember(watched: Bool, positionMs: Int64, editionId: Int64? = nil, itemId: Int64, profile: Int64) {
        let old = ledger.shelf.watch[profile]?[itemId]
        guard watched || positionMs > 0 || old != nil else { return }
        ledger.shelf.watch[profile, default: [:]][itemId] = WatchState(
            itemId: itemId, positionMs: positionMs, editionId: editionId, watched: watched,
            playCount: old?.playCount ?? 0, lastPlayedAt: positionMs > 0 || watched ? now() : old?.lastPlayedAt,
            updatedAt: now())
    }

    public func unsynced(_ profile: Int64) -> [Int64: LocalWatch] { ledger.unsynced[profile] ?? [:] }

    // MARK: Storage

    func save() {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        guard let data = try? Self.encoder.encode(ledger) else { return }
        try? data.write(to: ledgerFile, options: .atomic)
    }

    nonisolated static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ServerDates().encode(date))
        }
        return encoder
    }()

    nonisolated static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            try ServerDates().decode(decoder.singleValueContainer().decode(String.self))
        }
        return decoder
    }()
}
