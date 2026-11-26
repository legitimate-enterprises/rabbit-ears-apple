import Foundation
import XCTest

@testable import RabbitEarsKit

@MainActor
final class FakeBrowser: ServerBrowser {
    var onChange: (([FoundServer]) -> Void)?
    var onAvailability: ((Bool) -> Void)?
    var starts = 0
    var stops = 0
    func start() { starts += 1 }
    func stop() { stops += 1 }
}

@MainActor
final class ServerDiscoveryTests: XCTestCase {
    var browser: FakeBrowser!
    var discovery: ServerDiscovery!

    override func setUp() async throws {
        browser = FakeBrowser()
        discovery = ServerDiscovery(browser: browser)
    }

    func found(_ name: String, _ address: String) -> FoundServer {
        FoundServer(name: name, endpoint: ServerEndpoint(userInput: address)!)
    }

    func testListsWhatTheBrowserFindsByName() {
        discovery.start()
        XCTAssertEqual(browser.starts, 1)
        browser.onAvailability?(true)
        browser.onChange?([found("Rabbit Ears", "192.168.1.20"), found("Attic", "192.168.1.30:9000")])
        XCTAssertEqual(discovery.available, true)
        XCTAssertEqual(discovery.servers.map(\.name), ["Attic", "Rabbit Ears"])
        XCTAssertEqual(discovery.servers.map(\.address), ["192.168.1.30:9000", "192.168.1.20"])
        XCTAssertEqual(discovery.servers.last?.endpoint.baseURL.absoluteString, "http://192.168.1.20:8477")
    }

    func testSearchAgainForgetsAndBrowsesAfresh() {
        discovery.start()
        browser.onChange?([found("Rabbit Ears", "192.168.1.20")])
        discovery.restart()
        XCTAssertEqual(browser.stops, 1)
        XCTAssertEqual(browser.starts, 2)
        XCTAssertEqual(discovery.servers, [])
    }
}
