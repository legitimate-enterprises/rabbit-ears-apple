import Foundation
import GRDB
import HTTPTypes
import OpenAPIRuntime
import RabbitEarsAPI
import Synchronization
import XCTest

@testable import RabbitEarsKit

/// The server, its household's profiles each with a device of their own
/// for the server's truth, and the token of the device whose replica the
/// tests keep; seeded once per run.
@MainActor
final class SyncServer {
    struct Profile {
        let id: Int64
        let name: String
        let adult: Bool
        /// Read as an adult hiding kids' content.
        let hiding: Bool
        let rest: Client
    }

    let url: URL
    let deviceToken: String
    let profiles: [Profile]
    private let email: String
    private let password: String
    private let titles: [String: [ItemKind: Int64]]

    private static var made: SyncServer?
    private static var failure: (any Error)?

    static func shared() async throws -> SyncServer {
        if let made { return made }
        if let failure { throw failure }
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["RABBIT_EARS_UI_SERVER"], let url = URL(string: address),
            let email = environment["RABBIT_EARS_UI_EMAIL"], let password = environment["RABBIT_EARS_UI_PASSWORD"]
        else { throw XCTSkip("RABBIT_EARS_UI_SERVER, _EMAIL and _PASSWORD are not set") }
        do {
            let server = try await SyncServer(url: url, email: email, password: password)
            made = server
            return server
        } catch {
            // Seeded once: a failure fails every test the same way, with nothing seeded twice.
            failure = error
            throw error
        }
    }

    var adult: Profile { profiles[0] }

    func profile(_ name: String) throws -> Profile { try XCTUnwrap(profiles.first { $0.name == name && !$0.hiding }) }

    func movie(_ title: String) throws -> Int64 { try item(title, .movie) }

    func item(_ title: String, _ kind: ItemKind) throws -> Int64 { try XCTUnwrap(titles[title]?[kind], title) }

    private init(url: URL, email: String, password: String) async throws {
        (self.url, self.email, self.password) = (url, email, password)
        let (adultToken, me) = try await Self.signIn(url, email, password, "e2e truth")
        let rest = Client.connect(to: url, token: adultToken)
        deviceToken = try await Self.signIn(url, email, password, "e2e replica").0
        var profiles: [Profile] = []
        for profile in me.profiles {
            let adult = profile.kind == .adult
            var client = rest
            if !adult {
                client = Client.connect(
                    to: url, token: try await Self.signIn(url, email, password, "e2e \(profile.name)").0)
                _ = try await client.unlockProfile(path: .init(profileId: profile.id), body: .json(.init())).noContent
            }
            profiles.append(.init(id: profile.id, name: profile.name, adult: adult, hiding: false, rest: client))
            if adult, profile.id == me.account.id {
                profiles.append(
                    .init(id: profile.id, name: "\(profile.name) hiding", adult: true, hiding: true, rest: client))
            }
        }
        self.profiles = profiles
        var titles: [String: [ItemKind: Int64]] = [:]
        for kind in [ItemKind.movie, .show] {
            for item in try await Served.items(rest, kind) { titles[item.parsedTitle, default: [:]][kind] = item.id }
        }
        self.titles = titles
        try await seed(rest, me.account.id)
    }

    func signIn(_ name: String) async throws -> String { try await Self.signIn(url, email, password, name).0 }

    private static func signIn(
        _ url: URL, _ email: String, _ password: String, _ name: String
    ) async throws -> (String, Components.Schemas.Me) {
        let signed = try await Client.connect(to: url, token: nil).signIn(
            body: .json(.init(email: email, password: password, deviceName: name, platform: .macos))
        ).created.body.json
        return (signed.token, signed.me)
    }

    /// What the demo leaves out that a replica must carry: kids' titles, a
    /// kid on an allow list and a kids' channel, a shared playlist with
    /// entries, a collection, household stations over the playlist, one on
    /// air whenever it is read, and a kid's watch state.
    private func seed(_ rest: Client, _ adult: Int64) async throws {
        let sam = try profile("Sam")
        for title in ["Aurora", "Wildflower"] {
            _ = try await rest.setKidsContent(
                path: .init(itemId: try movie(title)), body: .json(.init(kidsContent: true))
            ).ok
        }
        // Sam sees what is allowed, Jamie what is rated for kids: no movie of the demo's, and one channel.
        _ = try await rest.replaceProfile(
            path: .init(profileId: sam.id),
            body: .json(.init(name: sam.name, birthday: "2014-01-01", filterMode: .allowList))
        ).ok
        let channels = try await rest.listYouTubeChannels().ok.body.json.items
        let channel = { (title: String) in try XCTUnwrap(channels.first { $0.title == title }?.id, title) }
        for id in [try movie("Golden Hour"), try item("The Guild", .show), try channel("Workbench Weekly")] {
            _ = try await rest.allowItem(path: .init(profileId: sam.id, itemId: id)).noContent
        }
        _ = try await rest.setYouTubeChannelForKids(
            path: .init(channelId: try channel("Clockwork Corner")), body: .json(.init(forKids: true))
        ).ok
        let playlist = try await rest.createPlaylist(
            path: .init(profileId: adult), body: .json(.init(name: "Evening", kind: .movies))
        ).created.body.json
        for title in ["Blue Horizon", "Aurora", "The Long Way Home"] {
            _ = try await rest.addPlaylistEntry(
                path: .init(profileId: adult, playlistId: playlist.id), body: .json(.init(itemId: try movie(title)))
            ).created
        }
        _ = try await rest.createPlaylistShare(
            path: .init(profileId: adult, playlistId: playlist.id), body: .json(.init(profileId: sam.id, access: .read))
        ).created
        let collection = try await rest.createCollection(body: .json(.init(name: "Favorites"))).created.body.json
        for title in ["Golden Hour", "Aurora"] {
            _ = try await rest.addCollectionMovie(path: .init(collectionId: collection.id, itemId: try movie(title)))
                .noContent
        }
        _ = try await rest.createStation(
            body: .json(.init(name: "Evening TV", playlistId: playlist.id, visibility: .household))
        ).created
        _ = try await rest.createStation(
            body: .json(.init(name: "Always on", playlistId: playlist.id, visibility: .household, timing: .continuous))
        ).created
        _ = try await sam.rest.putWatchState(
            path: .init(profileId: sam.id, itemId: try movie("Golden Hour")),
            body: .json(.init(watched: false, positionMs: 20_000, at: Date()))
        ).ok
    }
}

/// A device's replica, queue and engine wired as SyncSession wires them,
/// over the real transport, which keeps the path of each request. Its
/// queue flushes only when told, as a device with no network does.
@MainActor
final class SyncDevice {
    let directory: URL
    let replica: Replica
    let queue: ActionQueue
    let engine: SyncEngine
    let sent: SentPaths
    let notices: Heard
    let signOuts: Heard

    private struct Unsent: Error {}

    init(server: URL, token: String, directory: URL) throws {
        self.directory = directory
        let endpoint = ServerEndpoint(baseURL: server)
        let replica = Replica(directory: directory)
        try replica.open()
        let (sent, notices, signOuts) = (SentPaths(), Heard(), Heard())
        (self.sent, self.notices, self.signOuts) = (sent, notices, signOuts)
        let queue = ActionQueue(
            replica: replica, client: endpoint.client(token: token, transport: sent),
            notice: { operation, code in notices.add("\(operation) \(code ?? "")") },
            debounce: { try? await Task.sleep(for: .seconds(3600)) })
        self.replica = replica
        self.queue = queue
        engine = SyncEngine(
            replica: replica, endpoint: endpoint, token: token, transport: sent,
            flush: {
                guard !replica.isEmpty else { return }
                switch await queue.flush() {
                case .done: return
                case .refused(let error): throw error
                case .offline, .unsupported: throw Unsent()
                }
            }, signOut: { signOuts.add("signOut") })
    }

    /// The actions not yet sent.
    func queued() async throws -> Int? {
        try await replica.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM queue.action") }
    }

    /// The profile's position in the item, nil with no watch state.
    func position(_ profile: Int64, _ item: Int64) async throws -> Int64? {
        try await replica.read { db in
            try Int64.fetchOne(
                db, sql: "SELECT position_ms FROM watch_state WHERE account_id = ? AND item_id = ?",
                arguments: [profile, item])
        }
    }
}

final class SentPaths: ClientTransport, Sendable {
    private let log = Mutex<[String]>([])
    private let transport = Client.sharedTransport

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let path = String((request.path ?? "").prefix { $0 != "?" })
        log.withLock { $0.append(path) }
        return try await transport.send(request, body: body, baseURL: baseURL, operationID: operationID)
    }

    /// The sync requests sent, in order.
    func paths() -> [String] { log.withLock { $0.filter { $0.hasPrefix("/sync/") } } }

    func clear() { log.withLock { $0 = [] } }
}

final class Heard: Sendable {
    private let heard = Mutex<[String]>([])

    func add(_ notice: String) { heard.withLock { $0.append(notice) } }

    var all: [String] { heard.withLock { $0 } }
}

/// The server's listings, every page.
enum Served {
    static func items(_ client: Client, _ kind: ItemKind, kids: Bool? = nil) async throws -> [Item] {
        var out: [Item] = []
        var offset: Int? = 0
        while let at = offset {
            let page = try await client.listItems(query: .init(kind: kind, kidsContent: kids, limit: 200, offset: at))
                .ok.body.json
            out += page.items
            offset = page.nextOffset
        }
        return out
    }

    static func watchStates(_ client: Client, _ profile: Int64) async throws -> [WatchState] {
        var out: [WatchState] = []
        var offset: Int? = 0
        while let at = offset {
            let page = try await client.listWatchStates(
                path: .init(profileId: profile), query: .init(limit: 200, offset: at)
            ).ok.body.json
            out += page.items
            offset = page.nextOffset
        }
        return out
    }

    /// Today's programs, on this device's calendar, which is the server's.
    static func schedule(_ client: Client, _ station: Int64) async throws -> [StationProgram] {
        let today = Date().formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        var out: [StationProgram] = []
        var offset: Int? = 0
        while let at = offset {
            let page = try await client.listStationSchedule(
                path: .init(stationId: station), query: .init(date: today, limit: 200, offset: at)
            ).ok.body.json
            out += page.items
            offset = page.nextOffset
        }
        return out
    }

    static func watchState(_ client: Client, _ profile: Int64, _ item: Int64) async throws -> WatchState? {
        try await watchStates(client, profile).first { $0.itemId == item }
    }
}

/// Equality of what the server answers and what the replica reads, as
/// JSON with every item in it as the replica carries one: without a server
/// path (an admin's whole, a member's by name) or the instants of the
/// server's own refreshes, which no view reads. A failure names the lines
/// read (-) and served (+) that the other lacks.
enum Parity {
    static func list<T: Encodable>(_ mine: [T], _ theirs: [T], _ what: String, line: UInt = #line) {
        value(mine, theirs, what, line: line)
    }

    static func value<T: Encodable>(_ mine: T, _ theirs: T, _ what: String, line: UInt = #line) {
        let (read, served) = (lines(mine), lines(theirs))
        guard read != served else { return }
        let changes = served.difference(from: read).map { change in
            switch change {
            case .remove(let at, let line, _): (at, "\(at) - \(line)")
            case .insert(let at, let line, _): (at, "\(at) + \(line)")
            }
        }
        let named = changes.sorted { $0.0 < $1.0 }.prefix(40).map(\.1)
        XCTFail("\(what):\n\(named.joined(separator: "\n"))", line: line)
    }

    private static func lines(_ value: some Encodable) -> [String] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let data = try? encoder.encode(value),
            let json = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed),
            let shown = try? JSONSerialization.data(
                withJSONObject: shown(json),
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]),
            let text = String(bytes: shown, encoding: .utf8)
        else { return ["unencodable \(value)"] }
        return text.split(separator: "\n").map(String.init)
    }

    private static func shown(_ json: Any) -> Any {
        if let list = json as? [Any] { return list.map(shown) }
        guard var object = json as? [String: Any] else { return json }
        if object["parsedTitle"] != nil, object["libraryId"] != nil {
            object["path"] = nil
            object["updatedAt"] = object["addedAt"]
            if var metadata = object["metadata"] as? [String: Any] {
                metadata["fetchedAt"] = nil
                for key in ["posterPath", "backdropPath"] {
                    if let path = metadata[key] as? String, path.hasPrefix("/") {
                        metadata[key] = URL(filePath: path).lastPathComponent
                    }
                }
                object["metadata"] = metadata
            }
        }
        return object.mapValues(shown)
    }
}
