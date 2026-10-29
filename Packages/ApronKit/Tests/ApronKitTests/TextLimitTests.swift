import XCTest
@testable import ApronKit

final class TextLimitTests: XCTestCase {
    func testTextIsCountedInUTF8BytesAsSent() {
        XCTAssertEqual(TextLimit("  hello\n").used, 5, "trimmed")
        XCTAssertEqual(TextLimit("é").used, 2)
        XCTAssertEqual(TextLimit("👨‍👩‍👧‍👦").used, 25, "a family is four people and three joiners")
        XCTAssertEqual(TextLimit("🇳🇿").used, 8, "a flag is two regional indicators")
        XCTAssertEqual(TextLimit("//etc").used, 4, "a // message loses its first slash")
    }

    func testTheCounterShowsInTheLast512BytesAndSendingStopsPastTheLimit() {
        let under = TextLimit(String(repeating: "a", count: 3583))
        XCTAssertFalse(under.showsCounter)
        let near = TextLimit(String(repeating: "a", count: 3584))
        XCTAssertTrue(near.showsCounter)
        XCTAssertEqual(near.remaining, 512)
        let full = TextLimit(String(repeating: "👍", count: 1024))
        XCTAssertEqual([full.used, full.remaining], [4096, 0])
        XCTAssertFalse(full.isOver)
        let over = TextLimit(String(repeating: "👍", count: 1024) + "!")
        XCTAssertTrue(over.isOver)
        XCTAssertEqual(over.remaining, -1)
    }
}
