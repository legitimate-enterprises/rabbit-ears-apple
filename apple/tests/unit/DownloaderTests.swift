import Foundation
import Network
import XCTest

@testable import RabbitEarsKit

/// A loopback HTTP server that answers every request with the same five
/// bytes, holding the first `holding` until released, as the server holds
/// a file until its conversion is ready, or cutting the first `cutting`
/// short with a 524, as a proxy in front does with a hold past its limit.
final class FiveByteServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "five-byte-server")
    private var held: [NWConnection] = []
    private var count = 0
    /// Requests received, held ones included.
    var requests: Int { queue.sync { count } }

    init(holding: Int = 0, cutting: Int = 0) throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [unowned self] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [unowned self] _, _, _, _ in
                count += 1
                if count <= cutting {
                    Self.answer(
                        connection, "HTTP/1.1 524 A timeout occurred\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                } else if count <= holding {
                    held.append(connection)
                } else {
                    Self.answer(connection)
                }
            }
        }
    }

    private static func answer(
        _ connection: NWConnection,
        _ reply: String = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nmedia"
    ) {
        connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Answers every held request.
    func release() {
        queue.sync {
            for connection in held { Self.answer(connection) }
            held = []
        }
    }

    func start() async throws -> URL {
        let port = AsyncStream<NWEndpoint.Port?> { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready: continuation.yield(listener.port)
                case .failed, .cancelled: continuation.yield(nil)
                default: return
                }
                continuation.finish()
            }
            listener.start(queue: queue)
        }
        for await port in port {
            if let port { return try XCTUnwrap(URL(string: "http://127.0.0.1:\(port.rawValue)/file")) }
        }
        throw URLError(.cannotConnectToHost)
    }

    func stop() {
        listener.cancel()
        queue.sync { for connection in held { connection.cancel() } }
    }
}

final class DownloaderTests: XCTestCase {
    /// As in Application Support, where the app keeps its downloads.
    func testAFetchLandsAtADestinationWhosePathHasASpace() async throws {
        let server = try FiveByteServer()
        defer { server.stop() }
        let url = try await server.start()
        let folder = FileManager.default.temporaryDirectory.appending(path: "Application Support \(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appending(path: "media").appending(path: "5.m4a")
        try await URLSessionDownloader().fetch(URLRequest(url: url), to: destination, resumeData: nil) { _ in }
        XCTAssertEqual(try Data(contentsOf: destination), Data("media".utf8))
    }

    /// The server sends nothing while a conversion it waits on runs; a wait that outlasts the timeout asks again.
    func testAHeldFetchThatTimesOutAsksAgain() async throws {
        let server = try FiveByteServer(holding: 1)
        defer { server.stop() }
        let url = try await server.start()
        let folder = FileManager.default.temporaryDirectory.appending(path: "held \(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appending(path: "5.m4a")
        try await URLSessionDownloader(wait: 0.5).fetch(URLRequest(url: url), to: destination, resumeData: nil) { _ in }
        XCTAssertEqual(try Data(contentsOf: destination), Data("media".utf8))
        XCTAssertEqual(server.requests, 2)
    }

    /// A proxy in front cuts a hold past its limit short; the fetch asks again rather than failing.
    func testAHeldFetchAProxyCutsShortAsksAgain() async throws {
        let server = try FiveByteServer(cutting: 1)
        defer { server.stop() }
        let url = try await server.start()
        let folder = FileManager.default.temporaryDirectory.appending(path: "cut \(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appending(path: "5.m4a")
        try await URLSessionDownloader().fetch(URLRequest(url: url), to: destination, resumeData: nil) { _ in }
        XCTAssertEqual(try Data(contentsOf: destination), Data("media".utf8))
        XCTAssertEqual(server.requests, 2)
    }

    /// As a relaunched app finds the transfer its last process started still going.
    func testAFetchForADestinationAlreadyInFlightJoinsItsTransfer() async throws {
        let server = try FiveByteServer(holding: 1)
        defer { server.stop() }
        let url = try await server.start()
        let folder = FileManager.default.temporaryDirectory.appending(path: "joined \(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appending(path: "5.m4a")
        let downloader = URLSessionDownloader()
        let first = Task { try await downloader.fetch(URLRequest(url: url), to: destination, resumeData: nil) { _ in } }
        for _ in 0..<500 where server.requests == 0 { try await Task.sleep(for: .milliseconds(2)) }
        let second = Task {
            try await downloader.fetch(URLRequest(url: url), to: destination, resumeData: nil) { _ in }
        }
        try await Task.sleep(for: .milliseconds(100))
        server.release()
        try await first.value
        try await second.value
        XCTAssertEqual(server.requests, 1)
        XCTAssertEqual(try Data(contentsOf: destination), Data("media".utf8))
    }
}
