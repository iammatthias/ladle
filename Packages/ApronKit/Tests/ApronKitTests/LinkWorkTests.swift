import ApronKit
import XCTest

/// After apron-web's `link-controller.svelte.test.ts` (#209): one sign-in link at a time.
@MainActor
final class LinkWorkTests: XCTestCase {
    func testASecondLinkWhileOneIsUnderWayDoesNothingAndOneAfterRuns() async {
        let work = LinkWork()
        var ran: [String] = []
        let gate = AsyncStream<Void>.makeStream()
        XCTAssertTrue(work.run {
            ran.append("first")
            for await _ in gate.stream { break }
        })
        XCTAssertTrue(work.isBusy)
        XCTAssertFalse(work.run { ran.append("second") })
        gate.continuation.yield()
        await eventually("the first ends") { !work.isBusy }
        XCTAssertTrue(work.run { ran.append("third") })
        await eventually("the third ends") { !work.isBusy }
        XCTAssertEqual(ran, ["first", "third"])
    }
}
