import XCTest

/// Phase 2 drives a real server from here. Until then the scheme only proves it runs.
final class IntegrationPlaceholderTests: XCTestCase {
    func testSkipsWithoutServer() throws {
        let url = ProcessInfo.processInfo.environment["APRON_SERVER_URL"]
        try XCTSkipIf(url == nil, "set TEST_RUNNER_APRON_SERVER_URL to run integration tests")
    }
}
