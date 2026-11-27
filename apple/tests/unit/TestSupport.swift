import Foundation
import HTTPTypes
import OpenAPIRuntime
import RabbitEarsAPI
import RabbitEarsKit

extension UID {
    /// The server's test id uid.N(n): 00000000-0000-7000-8000-<n as 12 hex digits>, 0 <= n < 2^48.
    static func n(_ number: Int) -> UID {
        precondition((0..<(1 << 48)).contains(number), "uid.N takes 0 <= n < 2^48")
        return UID(String(format: "00000000-0000-7000-8000-%012llx", number))!
    }
}

// swift-format-ignore: AvoidRetroactiveConformances
/// So a test writes `item(1, ...)` for uid.N(1). Test bundles only: an app
/// that took an integer for an id would send what the server refuses.
extension UID: @retroactive ExpressibleByIntegerLiteral {
    public init(integerLiteral number: Int) { self = .n(number) }
}

/// UID.n(n) as an SQL BLOB literal, for SQL text that names an id.
func sqlID(_ number: Int) -> String { String(format: "x'00000000000070008000%012llx'", number) }

final class MemoryCredentialStore: CredentialStore {
    var server: URL?
    var serverName: String?
    var token: String?
    var profileMemories: [String: ProfileMemory] = [:]
}

/// Answers each request from a table keyed by "METHOD /path" (query
/// excluded) and records what was sent. Unknown routes answer 404.
final class RoutingTransport: ClientTransport, @unchecked Sendable {
    struct Sent {
        let method: HTTPRequest.Method
        let baseURL: URL
        let path: String
        let query: String
        let body: String
        let authorization: String?
    }

    var routes: [String: (HTTPResponse.Status, String)]
    /// Consulted before `routes`, for answers that depend on the request.
    var respond: ((Sent) -> (HTTPResponse.Status, String)?)?
    /// Awaited before each answer, for an address that never replies.
    var hold: (@Sendable (Sent) async throws -> Void)?
    var failure: (any Error)?
    /// Added to every answer.
    var headers = HTTPFields()
    /// Requests arrive off the main actor and may overlap, so the record is locked.
    private let sentLock = NSLock()
    private var sentLog: [Sent] = []
    var sent: [Sent] { sentLock.withLock { sentLog } }

    init(_ routes: [String: (HTTPResponse.Status, String)] = [:]) {
        self.routes = routes
    }

    func paths(_ method: HTTPRequest.Method) -> [String] {
        sent.filter { $0.method == method }.map(\.path)
    }

    func queries(_ method: HTTPRequest.Method, _ path: String) -> [String] {
        sent.filter { $0.method == method && $0.path == path }.map(\.query)
    }

    func body(_ method: HTTPRequest.Method, _ path: String) -> String? {
        sent.last { $0.method == method && $0.path == path }?.body
    }

    func json(_ method: HTTPRequest.Method, _ path: String) -> [String: Any]? {
        guard let body = body(method, path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
    }

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        if let failure { throw failure }
        // As URLSession: a cancelled task sends nothing, and one cancelled in flight reads no answer.
        try Task.checkCancellation()
        var text = ""
        if let body { text = try await String(collecting: body, upTo: 1 << 25) }
        let parts = (request.path ?? "").split(separator: "?", maxSplits: 1).map(String.init)
        let path = parts.first ?? ""
        let record = Sent(
            method: request.method, baseURL: baseURL, path: path, query: parts.count > 1 ? parts[1] : "", body: text,
            authorization: request.headerFields[.authorization])
        sentLock.withLock { sentLog.append(record) }
        try await hold?(record)
        let (status, reply) =
            respond?(record) ?? routes["\(request.method.rawValue) \(path)"] ?? (.notFound, Fixtures.error("not_found"))
        try Task.checkCancellation()
        var response = HTTPResponse(status: status)
        response.headerFields = headers
        response.headerFields[.contentType] = path.contains("/artwork/") ? "image/jpeg" : "application/json"
        return (response, reply.isEmpty ? nil : HTTPBody(reply))
    }
}

enum Fixtures {
    /// A replica directory of its own, for an AppModel or a catalog that reads nothing from it.
    static var replicas: URL { FileManager.default.temporaryDirectory.appending(path: "Replica \(UUID().uuidString)") }

    static func error(_ code: String, _ message: String = "nope") -> String {
        #"{"code":"\#(code)","message":"\#(message)"}"#
    }

    static func account(_ id: UID, _ name: String, kind: String = "adult", hasPin: Bool = false) -> String {
        #"{"id":"\#(id)","kind":"\#(kind)","name":"\#(name)","isAdmin":false,"hasPin":\#(hasPin),"#
            + #""pinLocked":false,"pending":false,"filterMode":"ratings","householdId":"\#(UID.n(1))","#
            + #""createdAt":"2026-01-01T00:00:00Z","modifiedAt":"2026-01-01T00:00:00.332Z"}"#
    }

    static let adult = account(1, "Avery")
    static let kid = account(2, "Robin", kind: "kid", hasPin: true)

    static let me =
        #"{"device":{"id":"\#(UID.n(9))","accountId":"\#(UID.n(1))","householdId":"\#(UID.n(1))","name":"Mac","#
        + #""platform":"macos","createdAt":"2026-01-01T00:00:00.680927Z","modifiedAt":"2026-01-01T00:00:00Z"},"#
        + #""account":\#(adult),"activeProfileId":"\#(UID.n(1))","#
        + #""household":{"id":"\#(UID.n(1))","name":"Avery","adultId":"\#(UID.n(1))","#
        + #""createdAt":"2026-01-01T00:00:00Z","modifiedAt":"2026-01-01T00:00:00Z"},"#
        + #""profiles":[\#(adult),\#(kid)]}"#

    static let signedIn = #"{"token":"tok-1","me":\#(me)}"#

    static func item(
        _ id: UID, _ kind: String, _ title: String, parent: UID? = nil, season: Int? = nil,
        episode: Int? = nil, added: String = "2026-01-01T00:00:00Z", runtime: Int? = nil, rating: String? = nil,
        year: Int? = nil, genres: [(UID, String)] = [], kids: Bool? = nil
    ) -> String {
        var fields = [
            #""id":"\#(id)""#, #""libraryId":"\#(UID.n(1))""#, #""kind":"\#(kind)""#, #""parsedTitle":"\#(title)""#,
            #""addedAt":"\#(added)""#, #""createdAt":"\#(added)""#, #""modifiedAt":"\#(added)""#,
        ]
        if let parent { fields.append(#""parentId":"\#(parent)""#) }
        if let season { fields.append(#""seasonNumber":\#(season)"#) }
        if let episode { fields.append(#""episodeNumber":\#(episode)"#) }
        if let year { fields.append(#""parsedYear":\#(year)"#) }
        if let kids { fields.append(#""kidsContent":\#(kids)"#) }
        var meta = [#""status":"matched""#]
        if let runtime { meta.append(#""runtimeMinutes":\#(runtime)"#) }
        if let rating { meta.append(#""contentRating":"\#(rating)""#) }
        fields.append(#""metadata":{\#(meta.joined(separator: ","))}"#)
        let genreList = genres.map { #"{"id":"\#($0.0)","name":"\#($0.1)"}"# }.joined(separator: ",")
        fields.append(#""genres":[\#(genreList)]"#)
        return "{\(fields.joined(separator: ","))}"
    }

    /// `total` is the match count across every page; it defaults to this page's rows.
    static func page(_ items: [String], total: Int? = nil) -> String {
        #"{"items":[\#(items.joined(separator: ","))],"total":\#(total ?? items.count)}"#
    }

    static func watch(
        _ item: UID, position: Int64 = 0, watched: Bool = false, played: String? = nil, edition: UID? = nil
    ) -> String {
        let last = played.map { #","lastPlayedAt":"\#($0)""# } ?? ""
        let cut = edition.map { #","editionId":"\#($0)""# } ?? ""
        return #"{"itemId":"\#(item)","positionMs":\#(position),"watched":\#(watched),"playCount":0,"#
            + #""changedAt":"2026-01-01T00:00:00Z"\#(last)\#(cut)}"#
    }

    /// Edition `UID.n(id)`, whose copies carry these quality labels, tallest
    /// first, in media files `UID.n(id * 10 + i)`.
    static func edition(
        _ id: Int, _ name: String, isDefault: Bool = false, runtimeMs: Int64? = nil, qualities: [String] = ["1080p"]
    ) -> String {
        let runtime = runtimeMs.map { #","runtimeMs":\#($0)"# } ?? ""
        let copies = qualities.enumerated().map { #"{"mediaFileId":"\#(UID.n(id * 10 + $0))","quality":"\#($1)"}"# }
        return #"{"id":"\#(UID.n(id))","name":"\#(name)","isDefault":\#(isDefault)\#(runtime),"#
            + #""copies":[\#(copies.joined(separator: ","))]}"#
    }

    /// A 400 naming one field, as the server answers a missing editionId.
    static func fieldError(_ field: String) -> String {
        #"{"code":"bad_request","message":"invalid request","fields":[{"field":"\#(field)","message":"needed"}]}"#
    }

    static let ladder =
        #"[{"width":3840,"height":2160,"bitrate":38000000,"verdict":"direct_play"},"#
        + #"{"width":1920,"height":1080,"bitrate":8000000,"verdict":"video_transcode"}]"#

    static func stream(
        session: UID = 7, url: String = "/api/v2/streams/k1/0/file", position: Int64 = 0,
        verdict: String = "direct_play", sidecars: String = "", rungs: String = ladder, extra: String = ""
    ) -> String {
        #"{"sessionId":"\#(session)","entry":{"position":0,"verdict":"\#(verdict)","videoAction":"copy","#
            + #""audioAction":"copy","subtitleAction":"none","bad":false},"streamUrl":"\#(url)","#
            + #""mediaFileId":"\#(UID.n(1))","streamKind":"file","positionMs":\#(position),"#
            + #""negotiated":{"verdict":"\#(verdict)","width":3840,"height":2160,"hdrFormat":"hdr10","#
            + #""bitrate":38000000},"rungs":\#(rungs),"#
            + #""sidecars":[\#(sidecars)]\#(extra)}"#
    }

    static let autoExtra =
        #","away":true,"auto":true,"previews":{"intervalMs":10000,"count":100,"width":320,"height":180,"#
        + #""frameUrl":"/api/v2/streams/k1/0/previews/{n}.jpg","bifUrl":"/api/v2/streams/k1/0/previews.bif"}"#

    static func update(_ action: String, _ stream: String) -> String {
        #"{"action":"\#(action)","stream":\#(stream)}"#
    }

    static func decode<T: Decodable>(_ json: String, as type: T.Type = T.self) -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: text))
            }
            return date
        }
        // swiftlint:disable:next force_try
        return try! decoder.decode(T.self, from: Data(json.utf8))
    }
}

extension CatalogModel {
    /// Over a replica with no snapshot, for what reads nothing from it.
    convenience init(client: Client, profileId: UID, hidingKids: Bool = false) {
        self.init(
            client: client, replica: Replica(directory: Fixtures.replicas), profileId: profileId,
            hidingKids: hidingKids)
    }

    /// Over `replica`, with a queue on it that sends through `client`.
    convenience init(client: Client, replica: Replica, profileId: UID, hidingKids: Bool = false) {
        self.init(
            client: client, replica: replica, queue: ActionQueue(replica: replica, client: client),
            profileId: profileId,
            hidingKids: hidingKids)
    }
}

/// Holds the server's answers until opened; after five seconds it opens by
/// itself, so a read that waits on it fails its test rather than hanging.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false

    func open() { lock.withLock { opened = true } }

    func wait() async throws {
        for _ in 0..<1000 where !lock.withLock({ opened }) { try await Task.sleep(for: .milliseconds(5)) }
    }
}
