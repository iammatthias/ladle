@testable import ApronKit
import Foundation
import XCTest

/// `Connection.probe` against a deployed server's connection-status endpoint. Skips unless
/// `APRON_LIVE_PROBE_URL` is set, so the hermetic suite never reaches the network.
/// `APRON_LIVE_PROBE_EXPECT` is the message the server should report; unset, the server must report none.
final class LiveProbeTests: XCTestCase {
    func testTheLiveServerAnswersTheProbe() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let text = environment["APRON_LIVE_PROBE_URL"], let url = URL(string: text) else {
            throw XCTSkip("APRON_LIVE_PROBE_URL is unset; this test runs only against a live server")
        }
        let report = await Connection.probe(url: url, origin: "https://app.apron.chat", fetch: ConnectionStatusProbe.live)
        print("live probe of \(text): \(String(describing: report))")
        XCTAssertEqual(report?.message, environment["APRON_LIVE_PROBE_EXPECT"])
    }
}
