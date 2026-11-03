@testable import ApronKit
import XCTest

/// A room's messages stay in numeric `message_id` order through the ways the index changes:
/// out-of-order arrival, a later snapshot of a held message, a move, and a raised floor.
final class ReplayStoreOrderTests: XCTestCase {
    private func snapshot(_ id: String, log: String? = nil, room: String = "general") -> MessageSnapshot {
        MessageSnapshot(messageID: LogID(id)!, logID: LogID(log ?? id)!, roomID: room, from: UserObject(["user_id": "ada"])!, body: ["text": .string(id)])
    }

    private func ids(_ store: ReplayStore, _ room: String = "general") -> [String] { store.messages(in: room).map(\.messageID.text) }

    func testMessagesKeepNumericOrderAsTheyArriveMoveAndExpire() {
        var store = ReplayStore()
        for id in ["300", "9", "1000", "20", "1000", "150"] { store.put(message: snapshot(id)) }
        XCTAssertEqual(ids(store), ["9", "20", "150", "300", "1000"], "numeric, not string, order; a repeat is held once")

        store.put(message: snapshot("150", log: "2000"))
        XCTAssertEqual(ids(store), ["9", "20", "150", "300", "1000"], "an edit keeps its place")
        XCTAssertEqual(store.message(LogID("150")!)?.logID.text, "2000")

        store.put(message: snapshot("300", log: "2001", room: "thread"))
        XCTAssertEqual(ids(store), ["9", "20", "150", "1000"], "a move takes it out of its room")
        XCTAssertEqual(ids(store, "thread"), ["300"])

        store.raiseFloor(of: "general", to: LogID("100")!)
        XCTAssertEqual(ids(store), ["150", "1000"], "below the floor goes")
        store.put(message: snapshot("50"))
        XCTAssertEqual(ids(store), ["150", "1000"], "and a late one below it is refused")
        store.put(message: snapshot("500"))
        XCTAssertEqual(ids(store), ["150", "500", "1000"])
    }
}
