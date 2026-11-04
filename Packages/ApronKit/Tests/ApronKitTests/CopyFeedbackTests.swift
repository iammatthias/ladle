import ApronKit
import XCTest

/// After apron-web's `CopyButton.svelte.test.ts` (#207).
final class CopyFeedbackTests: XCTestCase {
    func testACopyShowsCopiedAndALaterFailedOneClearsIt() {
        var feedback = CopyFeedback()
        XCTAssertFalse(feedback.copied)
        feedback.finish(true)
        XCTAssertTrue(feedback.copied)
        let first = feedback.generation
        feedback.finish(false)
        XCTAssertFalse(feedback.copied, "one that failed doesn't keep saying an earlier one copied")
        XCTAssertNotEqual(feedback.generation, first, "the wait starts over")
        feedback.finish(true)
        feedback.expire()
        XCTAssertFalse(feedback.copied)
        XCTAssertEqual(CopyFeedback.shown, .milliseconds(1500))
    }
}
