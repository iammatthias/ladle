@testable import ApronKit
import Foundation
import XCTest

final class JoinedCatchUpTests: XCTestCase {
    /// 2026-11-02 12:00 UTC.
    let now = Date(timeIntervalSince1970: 1_793_620_800)

    private func at(minutesAgo: Double) -> LogID { LogID(time: now.addingTimeInterval(-minutesAgo * 60)) }

    func testRoomsBehindCatchUpTogetherFromTheOldestCheckpoint() {
        let plan = JoinedCatchUp.plan(["general": at(minutesAgo: 30), "random": at(minutesAgo: 70)], now: now)
        XCTAssertEqual(plan, JoinedCatchUp(position: at(minutesAgo: 70), rooms: ["general", "random"]))
    }

    func testARoomQuietForOverAnHourBeforeTheOthersCatchesUpByItself() {
        let plan = JoinedCatchUp.plan(["general": at(minutesAgo: 10), "random": at(minutesAgo: 20), "garden": at(minutesAgo: 71)], now: now)
        XCTAssertEqual(plan, JoinedCatchUp(position: at(minutesAgo: 20), rooms: ["general", "random"]))
    }

    func testOneRoomOrAPositionOverADayOldCatchesUpRoomByRoom() {
        XCTAssertNil(JoinedCatchUp.plan(["general": at(minutesAgo: 10)], now: now))
        XCTAssertNil(JoinedCatchUp.plan(["general": at(minutesAgo: 24 * 60 + 1), "random": at(minutesAgo: 24 * 60 + 2)], now: now))
        XCTAssertNil(JoinedCatchUp.plan([:], now: now))
    }

    func testPositionsThatAreNotTimesAlwaysCatchUpTogether() {
        let plan = JoinedCatchUp.plan(["general": LogID("106")!, "random": LogID("9")!], now: now)
        XCTAssertEqual(plan, JoinedCatchUp(position: LogID("9")!, rooms: ["general", "random"]))
    }
}
