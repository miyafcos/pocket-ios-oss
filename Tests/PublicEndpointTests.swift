import XCTest
@testable import PocketIOS

final class PublicEndpointTests: XCTestCase {
    func testRelayHasNoBuiltInServer() {
        XCTAssertEqual(HarnessEndpoint.defaultBase, "")
        XCTAssertThrowsError(try APIClient(base: HarnessEndpoint.defaultBase))
    }

    func testExplicitRelayCanBeSavedAndCleared() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "public-endpoint-\(UUID().uuidString)"))
        XCTAssertEqual(try HarnessEndpoint.set("https://relay.example.test/pocket-relay", defaults: defaults),
                       "https://relay.example.test/pocket-relay/")
        XCTAssertEqual(HarnessEndpoint.base(defaults: defaults), "https://relay.example.test/pocket-relay/")
        XCTAssertEqual(try HarnessEndpoint.set("  \n", defaults: defaults), "")
        XCTAssertNil(defaults.string(forKey: HarnessEndpoint.key))
        XCTAssertEqual(HarnessEndpoint.base(defaults: defaults), "")
        XCTAssertEqual(try HarnessEndpoint.set("", defaults: defaults), "")
    }
}
