import XCTest
@testable import Apron

final class SmokeTests: XCTestCase {
    func testHostAppLoads() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.iammatthias.apron")
    }
}
