import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

extension AppModelTests {
    func testASignInTheDeviceCannotKeepSaysSoAndSignsItsTokenOut() async {
        /// A keychain that refuses the token, as a full or damaged one does.
        final class RefusingStore: CredentialStore {
            var server: URL?
            var serverName: String?
            var token: String? {
                get { nil }
                set {}  // swiftlint:disable:this unused_setter_value
            }
            var profileMemories: [String: ProfileMemory] = [:]
        }
        transport.routes["POST /auth/sign-out"] = (.noContent, "")
        model = AppModel(store: RefusingStore(), deviceName: "Test Mac", transport: transport)
        do {
            try await model.signIn(server: "rabbit.local", email: "a@example.test", password: "x")
            XCTFail("signed in with a token the device did not keep")
        } catch {
            XCTAssertNotNil(error as? AppError)
        }
        XCTAssertNil(model.client)
        XCTAssertNotEqual(model.phase, .choosingProfile)
        XCTAssertEqual(transport.sent.last?.path, "/auth/sign-out")
        XCTAssertEqual(transport.sent.last?.authorization, "Bearer tok-1")
    }
}
