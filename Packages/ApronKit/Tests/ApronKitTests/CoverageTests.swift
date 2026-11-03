@testable import ApronKit
import XCTest

final class CoverageTests: XCTestCase {
    private func span(_ lower: Int, _ upper: Int) -> LogSpan { LogSpan(LogID(String(lower))!, LogID(String(upper))!) }
    private func id(_ value: Int) -> LogID { LogID(String(value))! }

    func testInsertKeepsSpansAscendingAndDisjoint() {
        var coverage = Coverage()
        coverage.insert(span(900, 1000))
        coverage.insert(span(50, 99))
        coverage.insert(span(300, 400))
        XCTAssertEqual(coverage.spans, [span(50, 99), span(300, 400), span(900, 1000)])
        XCTAssertEqual(coverage.holes, [span(100, 299), span(401, 899)])
        XCTAssertEqual(coverage.oldest, span(50, 99))
        XCTAssertEqual(coverage.newest, span(900, 1000))
    }

    func testTouchingAndOverlappingSpansMergeIntoOne() {
        var coverage = Coverage([span(50, 99), span(900, 1000)])
        coverage.insert(span(100, 149))
        XCTAssertEqual(coverage.spans, [span(50, 149), span(900, 1000)], "side by side is one span")
        coverage.insert(span(120, 899))
        XCTAssertEqual(coverage.spans, [span(50, 1000)], "an overlap bridging two spans merges all three")
        coverage.insert(span(60, 70))
        XCTAssertEqual(coverage.spans, [span(50, 1000)], "a span already held changes nothing")
        XCTAssertEqual(coverage.holes, [])
    }

    func testHoldingAndTheSpanAboveAPosition() {
        let coverage = Coverage([span(50, 99), span(900, 1000)])
        XCTAssertEqual(coverage.index(holding: id(99)), 0)
        XCTAssertEqual(coverage.index(holding: id(900)), 1)
        XCTAssertNil(coverage.index(holding: id(100)))
        XCTAssertTrue(coverage.holds(id(950)))
        XCTAssertFalse(coverage.holds(id(1001)))
        XCTAssertEqual(coverage.span(above: id(100)), span(900, 1000))
        XCTAssertEqual(coverage.span(above: id(49)), span(50, 99))
        XCTAssertNil(coverage.span(above: id(1000)))
    }

    func testTheRetentionFloorDropsAndClampsSpans() {
        var coverage = Coverage([span(50, 99), span(300, 400), span(900, 1000)])
        coverage.dropBelow(id(350))
        XCTAssertEqual(coverage.spans, [span(350, 400), span(900, 1000)])
        coverage.dropBelow(id(100))
        XCTAssertEqual(coverage.spans, [span(350, 400), span(900, 1000)], "a floor below everything changes nothing")
    }

    func testAdvanceMovesOnlyTheNewestSpansUpperEdgeUp() {
        var coverage = Coverage([span(50, 99), span(900, 1000)])
        coverage.advance(to: id(1003))
        XCTAssertEqual(coverage.spans, [span(50, 99), span(900, 1003)])
        coverage.advance(to: id(990))
        XCTAssertEqual(coverage.spans, [span(50, 99), span(900, 1003)], "never back")
        var empty = Coverage()
        empty.advance(to: id(5))
        XCTAssertEqual(empty.spans, [])
    }

    func testASpanCountsItsPositions() {
        XCTAssertEqual(span(50, 99).count, 50)
        XCTAssertEqual(LogSpan(id(7), id(3)), span(3, 7), "edges given backwards are put in order")
    }
}
