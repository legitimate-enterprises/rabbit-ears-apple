import Foundation
import HTTPTypes
import OpenAPIRuntime
import RabbitEarsAPI

/// One API call as the downloads store reads it.
struct LocalCall: Sendable {
    let operation: String
    /// The path's segments below the API root, as `["items", "12"]`.
    let segments: [String]
    let query: [String: String]
    let body: Data?

    init(operation: String, path: String, body: Data?) {
        self.operation = operation
        let parts = URLComponents(string: path)
        segments = (parts?.path ?? path).split(separator: "/").map(String.init)
        var query: [String: String] = [:]
        for item in parts?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        self.query = query
        self.body = body
    }

    func id(after name: String) -> Int64? {
        segments.firstIndex(of: name).flatMap { segments.indices.contains($0 + 1) ? Int64(segments[$0 + 1]) : nil }
    }

    func number(_ name: String) -> Int64? { query[name].flatMap { Int64($0) } }

    func decode<T: Decodable>(_ type: T.Type) -> T? {
        body.flatMap { try? DownloadStore.decoder.decode(T.self, from: $0) }
    }
}

/// What the store answers in the server's place.
struct LocalAnswer: Sendable {
    let status: Int
    let body: Data?
    var contentType = "application/json"

    static let noContent = LocalAnswer(status: 204, body: nil)
    static let notFound = LocalAnswer(
        status: 404, body: Data(#"{"code":"not_found","message":"Not on this device."}"#.utf8))

    static func json<T: Encodable>(_ value: T, status: Int = 200) -> LocalAnswer {
        LocalAnswer(status: status, body: try? DownloadStore.encoder.encode(value))
    }
}

/// Lets every screen run on what is downloaded: plays a title kept on the
/// device from its file when the profile prefers local copies, and answers
/// what the store can while the server cannot be reached. On the way back
/// it notes who is signed in, for opening the app offline.
public struct OfflineMiddleware: ClientMiddleware {
    let store: DownloadStore

    public init(store: DownloadStore) { self.store = store }

    public func intercept(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var data: Data?
        if let body { data = try await Data(collecting: body, upTo: 16 << 20) }
        let call = LocalCall(operation: operationID, path: request.path ?? "", body: data)
        if let answer = await store.answerFirst(call) { return Self.response(answer) }
        let response: HTTPResponse
        let responseBody: HTTPBody?
        do {
            (response, responseBody) = try await next(request, data.map { HTTPBody($0) }, baseURL)
        } catch {
            guard Self.unreachable(error) else { throw error }
            if let answer = await store.answerOffline(call) { return Self.response(answer) }
            throw error
        }
        guard (200..<300).contains(response.status.code), store.notes(operationID) else {
            await store.reached()
            return (response, responseBody)
        }
        var answer = Data()
        if let responseBody { answer = try await Data(collecting: responseBody, upTo: 16 << 20) }
        await store.heard(call, answer: answer)
        return (response, HTTPBody(answer))
    }

    /// No answer at all, as opposed to the server refusing or the caller giving up.
    static func unreachable(_ error: any Error) -> Bool {
        if APIError.from(error) != nil || error is CancellationError || Task.isCancelled { return false }
        let inner = (error as? ClientError)?.underlyingError ?? error
        if inner is CancellationError { return false }
        return (inner as? URLError)?.code != .cancelled
    }

    /// Marks every answer made here rather than by the server.
    static let answeredHere = HTTPField.Name("Rabbit-Ears-Answered-Here")!

    static func response(_ answer: LocalAnswer) -> (HTTPResponse, HTTPBody?) {
        var response = HTTPResponse(status: .init(code: answer.status))
        response.headerFields[answeredHere] = "1"
        if answer.body != nil { response.headerFields[.contentType] = answer.contentType }
        // Artwork answers carry the validators the API requires of them; a kept image never changes.
        if answer.contentType.hasPrefix("image/") {
            response.headerFields[.eTag] = "\"offline\""
            response.headerFields[.cacheControl] = "private, no-cache"
        }
        return (response, answer.body.map { HTTPBody($0) })
    }
}

extension DownloadStore {
    /// Seconds an unanswered call keeps later ones from waiting on the network.
    static let offlineGrace: TimeInterval = 15

    /// A local session, or a title to play from its file; while the server
    /// was just found unreachable, anything the store can answer. Offline a
    /// kept copy plays whatever edition it is, as it plays the audio and
    /// quality it was kept with.
    func answerFirst(_ call: LocalCall) async -> LocalAnswer? {
        if call.segments.first == "playback", let id = call.id(after: "sessions"), id < 0 {
            return await session(id, call)
        }
        if call.operation == "startPlayback", let request = call.decode(Components.Schemas.PlaybackRequest.self),
            settings(request.profileId).preferLocal || isOffline,
            let answer = startLocal(request, anyEdition: isOffline)
        {
            return answer
        }
        return isOffline ? offline(call) : nil
    }

    func answerOffline(_ call: LocalCall) async -> LocalAnswer? {
        unreachableSince = now()
        if call.operation == "startPlayback", let request = call.decode(Components.Schemas.PlaybackRequest.self) {
            return startLocal(request, anyEdition: true)
        }
        return offline(call)
    }

    var isOffline: Bool {
        unreachableSince.map { now().timeIntervalSince($0) < Self.offlineGrace } ?? false
    }

    func reached() { unreachableSince = nil }

    nonisolated func notes(_ operation: String) -> Bool {
        ["getMe", "listLibraries", "unlockProfile", "lockDevice"].contains(operation)
    }

    /// Keeps the last Me, its lock and active profile, and the libraries, for
    /// the app to open with offline. A profile the household no longer has
    /// loses its downloads.
    func heard(_ call: LocalCall, answer: Data) {
        unreachableSince = nil
        switch call.operation {
        case "getMe":
            let me = try? Self.decoder.decode(Components.Schemas.Me.self, from: answer)
            ledger.shelf.me = me
            // Only the owner's answer lists pending adults, so only it names every profile the household has.
            guard let me, me.household?.adultId == me.activeProfileId else { break }
            let known = Set(ledger.requests.map(\.profileId)).union(ledger.settings.keys).union(ledger.unsynced.keys)
            for profile in known.subtracting(me.profiles.map(\.id)) { wipe(profile: profile) }
        case "listLibraries":
            guard let page = try? Self.decoder.decode(Components.Schemas.LibraryPage.self, from: answer) else {
                return
            }
            ledger.shelf.libraries = page.items
        case "unlockProfile":
            guard let id = call.id(after: "profiles") else { return }
            ledger.shelf.me?.activeProfileId = id
            ledger.shelf.me?.locked = false
        case "lockDevice": ledger.shelf.me?.locked = true
        default: return
        }
        save()
    }
}
