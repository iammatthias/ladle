import XCTest
@testable import ApronKit

/// ↑ ↓ Tab Return and Escape in the composer's lists, as apron-web's `DraftField.keydown`.
final class SuggestionCursorTests: XCTestCase {
    func testArrowsMoveAndWrapAndTabOrReturnPicks() {
        var cursor = SuggestionCursor()
        cursor.follow(.mention("a"), text: "@a")
        XCTAssertEqual(cursor.highlighted(count: 3), 0)
        XCTAssertEqual(cursor.press(.up, count: 3, text: "@a"), .moved)
        XCTAssertEqual(cursor.highlighted(count: 3), 2, "up from the top wraps to the bottom")
        XCTAssertEqual(cursor.press(.down, count: 3, text: "@a"), .moved)
        XCTAssertEqual(cursor.highlighted(count: 3), 0, "down from the bottom wraps to the top")
        _ = cursor.press(.down, count: 3, text: "@a")
        XCTAssertEqual(cursor.press(.tab, count: 3, text: "@a"), .pick(1))
        _ = cursor.press(.down, count: 3, text: "@a")
        XCTAssertEqual(cursor.press(.enter, count: 3, text: "@a"), .pick(1))
        XCTAssertEqual(cursor.press(.enter, count: 0, text: "@a"), .ignored, "no rows, Return sends")
    }

    func testTheRowKeepsWhileTypingOnAndStartsAgainForANewList() {
        var cursor = SuggestionCursor()
        cursor.follow(.emoji("sm"), text: ":sm")
        _ = cursor.press(.down, count: 8, text: ":sm")
        _ = cursor.press(.down, count: 8, text: ":sm")
        cursor.follow(.emoji("smi"), text: ":smi")
        XCTAssertEqual(cursor.highlighted(count: 8), 2)
        XCTAssertEqual(cursor.highlighted(count: 2), 1, "clamped to a list that shrank")
        cursor.follow(nil, text: ":smi ")
        cursor.follow(.room("d"), text: ":smi #d")
        XCTAssertEqual(cursor.highlighted(count: 8), 0)
        cursor.hover(5)
        XCTAssertEqual(cursor.highlighted(count: 8), 5)
    }

    func testEscapePutsTheListAwayUntilTheTextChanges() {
        var cursor = SuggestionCursor()
        cursor.follow(.command("in"), text: "/in")
        XCTAssertEqual(cursor.press(.escape, count: 2, text: "/in"), .dismissed)
        XCTAssertFalse(cursor.shows("/in"))
        XCTAssertEqual(cursor.press(.enter, count: 2, text: "/in"), .ignored, "Return then sends")
        XCTAssertEqual(cursor.press(.escape, count: 2, text: "/in"), .ignored, "and Escape cancels a reply")
        cursor.follow(.command("in"), text: "/in")
        XCTAssertFalse(cursor.shows("/in"))
        cursor.follow(.command("inv"), text: "/inv")
        XCTAssertTrue(cursor.shows("/inv"))
    }
}
