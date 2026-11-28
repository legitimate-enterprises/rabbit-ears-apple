import Foundation
import GRDB
import Observation
import RabbitEarsAPI

/// Everything the device keeps for offline play, written to one file
/// beside the media it describes.
struct DownloadLedger: Codable, Sendable {
    var server: URL?
    var wifiOnly = true
    var allowanceBytes: Int64 = 20 << 30
    var settings: [UID: DownloadSettings] = [:]
    var requests: [DownloadRequest] = []
    var titles: [UID: StoredTitle] = [:]
    var shelf = OfflineShelf()
}

/// The device's downloads: each profile's requests, the one stored copy of
/// each title they cover, reference counted across requests and profiles,
/// and the artwork they show with offline. What the titles are and how far
/// each profile has watched them is the replica's.
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
    /// The signed-in server's replica, which says who is active here and what each profile has watched.
    var replica: Replica?
    var plays: LocalPlays?
    public private(set) var libraries: [DownloadLibrary] = []
    var pumping = false
    /// A pump was asked for while one claimed, so another follows it.
    var pumpAgain = false
    /// By title: each transfer in flight; true unless the server stopped it.
    var transfers: [UID: Task<Bool, Never>] = [:]
    var watchingPath = false
    var waitingToPump = false
    /// Pumps stopped in a row, which lengthen the wait before the next.
    var stops = 0
    /// The last time a call found no server, which offline answers trust for a while.
    var unreachableSince: Date?
    var sessions: [UID: LocalSession] = [:]

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
        if let data = try? Data(contentsOf: ledgerFile) {
            if let saved = try? Self.decoder.decode(DownloadLedger.self, from: data) {
                ledger = saved
            } else {
                // A ledger this version cannot read holds nothing; the files it described go.
                collect()
            }
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
    /// A local play's watch state goes to `plays`.
    func connect(
        client: Client, endpoint: ServerEndpoint, token: String, replica: Replica? = nil, plays: LocalPlays? = nil
    ) {
        if let server = ledger.server, server != endpoint.baseURL { wipe() }
        ledger.server = endpoint.baseURL
        link = Link(client: client, endpoint: endpoint, token: token)
        self.replica = replica
        self.plays = plays
        save()
        Task { await loadLibraries() }
    }

    /// Signed out or revoked: every download and what describes it goes.
    public func wipe() {
        link = nil
        replica = nil
        plays = nil
        libraries = []
        sessions = [:]
        downloader.cancelAll()
        try? FileManager.default.removeItem(at: directory)
        ledger = DownloadLedger(wifiOnly: ledger.wifiOnly, allowanceBytes: ledger.allowanceBytes)
        save()
    }

    /// A profile the server no longer knows: its requests go, and what only they held.
    public func wipe(profile: UID) {
        ledger.requests.removeAll { $0.profileId == profile }
        ledger.settings[profile] = nil
        collect()
    }

    // MARK: Reading

    public var requests: [DownloadRequest] { ledger.requests }
    public var titles: [UID: StoredTitle] { ledger.titles }
    /// Whether this server has anything kept here, so the app may open without it.
    public var hasDownloads: Bool { !ledger.requests.isEmpty }

    public func requests(for profile: UID) -> [DownloadRequest] {
        ledger.requests.filter { $0.profileId == profile }
    }

    public func request(_ target: DownloadTarget, profile: UID) -> DownloadRequest? {
        ledger.requests.first { $0.profileId == profile && $0.target == target }
    }

    /// The title's stored copy when the profile's requests cover it and it is all on the device.
    public func onDevice(_ itemId: UID, profile: UID) -> StoredTitle? {
        guard let title = ledger.titles[itemId], title.state == .onDevice,
            requests(for: profile).contains(where: { $0.titles.contains(itemId) })
        else { return nil }
        return title
    }

    /// For the artwork badge: a title on the device, or the profile's request
    /// for exactly this container whose every title is.
    public func badged(_ id: UID, scope: DownloadTarget.Scope = .item, profile: UID) -> Bool {
        if scope == .item, onDevice(id, profile: profile) != nil { return true }
        guard let request = requests(for: profile).first(where: { $0.target.scope == scope && $0.target.id == id }),
            !request.titles.isEmpty
        else { return false }
        return request.titles.allSatisfy { ledger.titles[$0]?.state == .onDevice }
    }

    var offlineFilter = OfflineFilter()

    public func file(of title: StoredTitle) -> URL? { title.file.map { media.appending(path: $0) } }

    /// The server's libraries as the replica has them, by name as the server lists them.
    public func loadLibraries() async {
        guard let replica,
            let read = try? await replica.read({ db in
                try Row.fetchAll(db, sql: "SELECT id, name, kind FROM library ORDER BY name, id").compactMap { row in
                    Components.Schemas.LibraryKind(rawValue: row["kind"]).map {
                        DownloadLibrary(id: row["id"], name: row["name"], kind: $0)
                    }
                }
            })
        else { return }
        libraries = read
    }

    /// The Me the app keeps for this server: who is active here, and the household's profiles.
    var me: Components.Schemas.Me? {
        guard let link, let kept = replica?.kept(AppModel.keptMe(link.endpoint)) else { return nil }
        return try? Self.decoder.decode(Components.Schemas.Me.self, from: kept)
    }

    /// The profile's watch state of the item in the replica.
    func watchState(_ itemId: UID, profile: UID) async -> WatchState? {
        try? await replica?.read { db in
            try Row.fetchOne(
                db, sql: "SELECT * FROM watch_state WHERE account_id = ? AND item_id = ?", arguments: [profile, itemId]
            ).map(ReplicaRows.watchState)
        } ?? nil
    }

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

    public func settings(_ profile: UID) -> DownloadSettings { ledger.settings[profile] ?? DownloadSettings() }

    public func setSettings(_ settings: DownloadSettings, for profile: UID) {
        let before = self.settings(profile)
        ledger.settings[profile] = settings
        save()
        if settings.keep != before.keep { Task { await applyKeepPolicy(profile) } }
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
    public func remove(_ target: DownloadTarget, profile: UID) {
        ledger.requests.removeAll { $0.profileId == profile && $0.target == target }
        collect()
    }

    public func retry(_ itemId: UID) {
        guard case .failed = ledger.titles[itemId]?.state else { return }
        ledger.titles[itemId]?.state = .pending
        save()
        Task { await pump() }
    }

    /// Sets what a request covers from a resolution: everything available,
    /// but in a standing request not the watched titles of a library that
    /// removes them. New titles wait to download; dropped ones go when
    /// nothing else holds them.
    func apply(_ resolved: [DownloadTitle], to target: DownloadTarget, profile: UID, quality: DownloadQuality) {
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
        collect()
    }

    /// Drops from the profile's requests what the server says it may no longer keep.
    func drop(_ itemIds: Set<UID>, profile: UID) {
        guard !itemIds.isEmpty else { return }
        for index in ledger.requests.indices where ledger.requests[index].profileId == profile {
            ledger.requests[index].titles.removeAll { itemIds.contains($0) }
        }
        collect()
    }

    /// Takes titles the replica has watched out of the profile's standing requests where their library removes them.
    func applyKeepPolicy(_ profile: UID) async {
        guard let replica,
            let watched = try? await replica.read({ db in
                try UID.fetchSet(
                    db, sql: "SELECT item_id FROM watch_state WHERE account_id = ? AND watched", arguments: [profile])
            })
        else { return }
        let settings = settings(profile)
        let titles = ledger.titles
        for index in ledger.requests.indices
        where ledger.requests[index].profileId == profile && ledger.requests[index].target.standing {
            ledger.requests[index].titles.removeAll { id in
                guard let title = titles[id], watched.contains(id) else { return false }
                return !settings.keeps(library: title.libraryId, kind: title.kind)
            }
        }
        collect()
    }

    /// Deletes every stored title no request holds, with its files, any
    /// file in media/ no stored title holds, and the artwork nothing kept
    /// shows with; its transfer stops and the server lets its claim go.
    func collect() {
        let held = Set(ledger.requests.flatMap(\.titles))
        let me = me
        for (id, title) in ledger.titles where !held.contains(id) {
            transfers[id]?.cancel()
            if let claim = title.claim, let link { Task { _ = await release(claim, link, me) } }
            ledger.titles[id] = nil
        }
        // Each media file's name starts with its title's id, so one that
        // landed before its title names it is kept; a name without one is stale.
        let files = (try? FileManager.default.contentsOfDirectory(atPath: media.path(percentEncoded: false))) ?? []
        for name in files where UID(String(name.prefix(36))).flatMap({ ledger.titles[$0] }) == nil {
            try? FileManager.default.removeItem(at: media.appending(path: name))
        }
        ledger.shelf.art.formIntersection(
            ledger.titles.values.flatMap { $0.art ?? [] } + ledger.requests.flatMap { $0.art ?? [] })
        let names = (try? FileManager.default.contentsOfDirectory(atPath: art.path(percentEncoded: false))) ?? []
        for name in names where !ledger.shelf.art.contains(name) {
            try? FileManager.default.removeItem(at: art.appending(path: name))
        }
        save()
    }

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
