@testable import ApronKit
import XCTest

@MainActor
final class RequestFeedbackTests: XCTestCase {
    private struct Refused: Error {}

    func testAQuickRequestShowsNothingAndASlowOneSaysItIsPendingUntilDone() async {
        let quiet = AsyncStream<Void>.makeStream()
        let feedback = RequestFeedback(sleep: { _ in for await _ in quiet.stream { return } })
        let done = AsyncStream<Void>.makeStream()
        let slow = Task { await feedback.track("Leaving…") { for await _ in done.stream { return } } }
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(feedback.current, "not before 600 ms")
        quiet.continuation.yield()
        await eventually("pending") { feedback.current?.kind == .pending }
        XCTAssertEqual(feedback.current?.text, "Leaving…")
        done.continuation.yield()
        await slow.value
        XCTAssertNil(feedback.current, "gone once it is done")

        await feedback.track("Joining…") {}
        XCTAssertNil(feedback.current)
    }

    func testAFailureStaysUntilTheNextRequestOrItsDismissal() async throws {
        let feedback = RequestFeedback(sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        await feedback.track("Reacting…") { throw RPCError(code: RPCError.Code.denied, message: "No such message") }
        let failed = try XCTUnwrap(feedback.current)
        XCTAssertEqual(failed.kind, .error)
        XCTAssertEqual(failed.text, "No such message")
        await feedback.track("Reacting…") {}
        XCTAssertNil(feedback.current, "the next request takes it")

        await feedback.track("Deleting message…") { throw Refused() }
        let again = try XCTUnwrap(feedback.current)
        feedback.dismiss(again)
        XCTAssertNil(feedback.current)
    }
}
