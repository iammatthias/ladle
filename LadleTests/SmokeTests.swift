import XCTest
@testable import Ladle

final class SmokeTests: XCTestCase {
    func testHostAppLoads() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "app.ladle.ios")
    }
}
