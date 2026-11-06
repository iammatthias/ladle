@testable import ApronKit
import XCTest

/// A field of the wrong type is read as absent (EXTENSIONS.md's unknown-value rule), as apron-web
/// #223's 'leaves out a field of the wrong type, as if absent'.
final class RecordsDecodingTests: XCTestCase {
    private let base: [String: JSONValue] = ["message_id": "1", "log_id": "1", "room_id": "general", "from": ["user_id": "ada"]]

    private func message(_ fields: [String: JSONValue]) -> MessageSnapshot? {
        Records(messageParams: .object(base.merging(fields) { _, new in new })).messages.first
    }

    func testAMessagesWrongTypedFieldsAreAbsent() throws {
        let odd = try XCTUnwrap(message(["body": "hi", "deleted": "yes", "ext": ["a"]]))
        XCTAssertEqual([odd.body == nil, odd.ext == nil, odd.deleted == nil], [true, true, true])
        XCTAssertEqual(message(["body": ["hi"]]).map { $0.body == nil }, true)
        let fine = try XCTUnwrap(message(["body": ["text": "hi"], "deleted": true, "ext": ["a": 1]]))
        XCTAssertEqual(fine.body, ["text": "hi"])
        XCTAssertEqual(fine.ext, ["a": 1])
        XCTAssertEqual(fine.deleted, true)
    }

    func testARoomsWrongTypedFieldsAreAbsent() throws {
        let records = Records(roomListResult: ["joined": [["room_id": "x", "title": ["text": "General"], "description": 42, "ext": "x"]]])
        let room = try XCTUnwrap(records.rooms.first?.0)
        XCTAssertEqual([room.title == nil, room.description == nil, room.ext == nil], [true, true, true])
        let named = Records(roomListResult: ["joined": [["room_id": "y", "title": "General", "description": "", "ext": ["a": 1]]]])
        let kept = try XCTUnwrap(named.rooms.first?.0)
        XCTAssertEqual([kept.title, kept.description, kept.ext], ["General", "", ["a": 1]])
    }
}
