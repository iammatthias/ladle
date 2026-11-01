import XCTest
@testable import ApronKit

final class KeyboardCommandsTests: XCTestCase {
    private let order = ["10", "11", "12", "13"].map { LogID($0)! }

    func testXStartsSelectModeThenPicksAndUnpicks() throws {
        let started = try XCTUnwrap(KeyboardCommands.pressX(on: LogID("11")!, selection: nil, roomID: "general", order: order))
        XCTAssertEqual(started.roomID, "general")
        XCTAssertEqual(started.ids, [LogID("11")!])
        let grown = try XCTUnwrap(KeyboardCommands.pressX(on: LogID("13")!, selection: started, roomID: "general", order: order))
        XCTAssertEqual(grown.ids, [LogID("11")!, LogID("13")!], "one message, not a range")
        let shrunk = try XCTUnwrap(KeyboardCommands.pressX(on: LogID("11")!, selection: grown, roomID: "general", order: order))
        XCTAssertEqual(shrunk.ids, [LogID("13")!])
        XCTAssertNil(KeyboardCommands.pressX(on: LogID("13")!, selection: shrunk, roomID: "general", order: order),
                     "unpicking the last one ends select mode")
    }

    func testArrowsStepThroughTheViewerAndStopAtTheEnds() {
        let items = ["a", "b", "c"].map {
            MediaItem(id: $0, media: URL(string: "https://chat.example/\($0)")!, original: nil, name: $0, alt: nil, sender: "Ada", date: .distantPast)
        }
        XCTAssertEqual(KeyboardCommands.step(items, from: "b", by: 1), "c")
        XCTAssertEqual(KeyboardCommands.step(items, from: "b", by: -1), "a")
        XCTAssertNil(KeyboardCommands.step(items, from: "c", by: 1), "no wrap past the last")
        XCTAssertNil(KeyboardCommands.step(items, from: "a", by: -1))
        XCTAssertNil(KeyboardCommands.step(items, from: "gone", by: 1))
    }
}
