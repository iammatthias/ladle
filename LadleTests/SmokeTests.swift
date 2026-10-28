import XCTest
@testable import Ladle

final class SmokeTests: XCTestCase {
    func testHostAppLoads() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.iammatthias.ladle")
    }
}
