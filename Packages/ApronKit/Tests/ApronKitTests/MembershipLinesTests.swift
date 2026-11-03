import XCTest
@testable import ApronKit

@MainActor
final class MembershipLinesTests: XCTestCase {
    private func user(_ id: String, _ name: String? = nil) -> UserObject {
        UserObject(["user_id": .string(id), "name": .string(name ?? id.capitalized)])!
    }

    private func record(_ log: String, _ entries: [(String, Bool)]) -> MembershipRecord {
        MembershipRecord(logID: LogID(log)!, entries: entries.map { MembershipRecord.Entry(user: user($0.0), joined: $0.1) })
    }

    func testARunNetsEachUserFromTheirFirstEntryToTheirLast() {
        let net = MembershipLines.net([
            record("10", [("ada", true), ("bob", true)]),
            record("11", [("carol", false), ("bob", false)]),
            record("12", [("dev", false)]),
            record("13", [("dev", true), ("ada", true)]),
        ])
        XCTAssertEqual(net.joined.map(\.userID), ["ada"], "Bob came and went; Ada joined twice")
        XCTAssertEqual(net.left.map(\.userID), ["carol"], "Dev left and came back")
    }

    func testEachUserIsTheirLatestObjectInTheRun() {
        let renamed = MembershipRecord(logID: LogID("2")!, entries: [.init(user: user("ada", "Ada L"), joined: true)])
        XCTAssertEqual(MembershipLines.net([record("1", [("ada", true)]), renamed]).joined.first?.json["name"], "Ada L")
    }

    func testABaselineIsTwentyOneJoinsOrMore() {
        let joins = (1 ... 21).map { ("u\($0)", true) }
        XCTAssertTrue(record("5", joins).isBaseline)
        XCTAssertFalse(record("5", Array(joins.prefix(20))).isBaseline)
        XCTAssertFalse(record("5", joins + [("gone", false)]).isBaseline, "a leave in it makes it something that happened")
        XCTAssertEqual(MembershipLines.baselineMin, 21)
    }

    func testNamesAreListedThreeAtMost() {
        XCTAssertEqual(MembershipLines.list(["Ada"]), "Ada")
        XCTAssertEqual(MembershipLines.list(["Ada", "Bob"]), "Ada and Bob")
        XCTAssertEqual(MembershipLines.list(["Ada", "Bob", "Carol"]), "Ada, Bob, and Carol")
        XCTAssertEqual(MembershipLines.list(["Ada", "Bob", "Carol", "Dev", "Eun-ji", "Fay"]), "Ada, Bob, and 4 others")
    }

    func testALineSaysWhoJoinedThenWhoLeftAndSpellsOutCountedNames() {
        XCTAssertEqual(MembershipLines.summary(joined: ["Ada", "Bob"], left: ["Carol"]).text, "Ada and Bob joined · Carol left")
        XCTAssertNil(MembershipLines.summary(joined: ["Ada"], left: []).full)
        let counted = MembershipLines.summary(joined: ["Ada", "Bob", "Carol", "Dev"], left: ["Eun-ji"])
        XCTAssertEqual(counted.text, "Ada, Bob, and 2 others joined · Eun-ji left")
        XCTAssertEqual(counted.full, "Joined: Ada, Bob, Carol, Dev\nLeft: Eun-ji")
    }

    func testARenameLineNamesTheNewTitle() {
        XCTAssertEqual(MembershipLines.rename("Ops", thread: false), "Room renamed to “Ops”")
        XCTAssertEqual(MembershipLines.rename("Deploy", thread: true), "Thread renamed to “Deploy”")
        XCTAssertEqual(MembershipLines.rename("", thread: true), "Thread name cleared")
        XCTAssertEqual(MembershipLines.rename("\u{202E}Ops", thread: false), "Room renamed to “Ops”")
    }

    func testTheStoreLogsEveryMembershipAndTitleItSees() throws {
        var store = ReplayStore()
        let room = { (log: String, title: String?) -> JSONValue in
            var record: [String: JSONValue] = ["room_id": "ops", "log_id": .string(log)]
            if let title { record["title"] = .string(title) }
            return .object(record)
        }
        let member = { (log: String, id: String, joined: Bool) -> JSONValue in
            ["log_id": .string(log), "room_id": "ops", "members": [["user": ["user_id": .string(id)], "joined": .bool(joined)]]]
        }
        store.apply(Records(historyResult: [
            "rooms": [room("30", "Incidents"), room("10", "Ops"), room("20", "Ops"), room("40", nil)],
            "memberships": [member("25", "bob", true), member("15", "ada", true), member("15", "cy", true), member("15", "ada", true)],
        ]))
        XCTAssertEqual(store.renames(of: "ops"), [
            RoomRename(logID: LogID("30")!, title: "Incidents", previous: "Ops"),
            RoomRename(logID: LogID("40")!, title: "", previous: "Incidents"),
        ])
        XCTAssertEqual(store.membershipLog(of: "ops").map { [$0.logID.text] + $0.entries.map(\.user.userID) }, [["15", "ada", "cy"], ["25", "bob"]])
        store.raiseFloor(of: "ops", to: LogID("20")!)
        XCTAssertEqual(store.membershipLog(of: "ops").map(\.logID.text), ["25"], "records below the retention floor go")
    }

    func testTheTimelineShowsJoinsAndRenamesAmongTheMessages() async throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let store = await PreviewFixtures.makeStore()
        let home = try XCTUnwrap(store.session(for: PreviewFixtures.homeID))
        let general = home.timelineItems("general", lineBefore: nil, calendar: utc)
        let lines = general.compactMap { item -> String? in if case .members(let line) = item { home.words(line).text } else { nil } }
        XCTAssertEqual(lines, ["Dev joined"], "the guest who came and went nets out")
        let line = try XCTUnwrap(general.first { $0.id.hasPrefix("members-") })
        XCTAssertEqual(line.id, "members-1793092750000", "keyed by the run's first record")
        let after = try XCTUnwrap(general.firstIndex { $0.id == line.id })
        guard case .message(let moved, let continues, _) = general[after + 1] else { return XCTFail("the moved message follows") }
        XCTAssertEqual(moved.from.userID, "dev")
        XCTAssertFalse(continues)

        let thread = home.timelineItems(PreviewFixtures.releaseThreadID, lineBefore: nil, calendar: utc)
        let renames = thread.compactMap { item -> String? in if case .renamed(let rename) = item { rename.title } else { nil } }
        XCTAssertEqual(renames, ["Release 0.2"])
    }
}
