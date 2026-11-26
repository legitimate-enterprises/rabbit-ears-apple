import XCTest

@testable import RabbitEarsKit

final class ServerEndpointTests: XCTestCase {
    func testAcceptsAHostOrAURL() {
        let cases = [
            "media.example.test": "http://media.example.test:8477",
            "  media.example.test:9000 ": "http://media.example.test:9000",
            "https://media.example.test": "https://media.example.test",
            "http://10.0.0.5:8477/join/ABCD-EFGH": "http://10.0.0.5:8477",
            "HTTP://Media.Example.Test/": "http://media.example.test",
        ]
        for (input, want) in cases {
            XCTAssertEqual(ServerEndpoint(userInput: input)?.baseURL.absoluteString, want, input)
        }
        XCTAssertNil(ServerEndpoint(userInput: ""))
        XCTAssertNil(ServerEndpoint(userInput: "ftp://media.example.test"))
        XCTAssertNil(ServerEndpoint(userInput: "has space"))
    }

    func testLocalNetworkMeansAPrivateOrLinkLocalHost() {
        let local = [
            "localhost", "mini.local", "10.1.2.3", "172.16.0.1", "172.31.9.9", "192.168.1.20", "169.254.1.1",
            "[fd00::1]", "[fe80::1]", "127.0.0.1",
        ]
        let remote = [
            "media.example.test", "8.8.8.8", "172.32.0.1", "[2001:db8::1]", "100.64.0.1", "10.0.0.1.example.com",
        ]
        for host in local { XCTAssertTrue(ServerEndpoint(userInput: host)!.isLocalNetwork, host) }
        for host in remote { XCTAssertFalse(ServerEndpoint(userInput: host)!.isLocalNetwork, host) }
    }

    func testResolvesServerRelativeStreamPaths() {
        let endpoint = ServerEndpoint(userInput: "https://media.example.test:9000")!
        XCTAssertEqual(
            endpoint.resolve("/api/v1/streams/k/0/master.m3u8").absoluteString,
            "https://media.example.test:9000/api/v1/streams/k/0/master.m3u8")
    }
}
