import XCTest
@testable import ApronKit

@MainActor
final class TimelineTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func home() async throws -> ServerSession {
        let store = await PreviewFixtures.makeStore()
        return try XCTUnwrap(store.session(for: PreviewFixtures.homeID))
    }

    private func names(_ items: [TimelineItem], in session: ServerSession) -> [String] {
        items.map { item in
            switch item {
            case .message(let message, let continues): message.from.userID + (continues ? "+" : "")
            case .day(let date): "day \(Int(date.timeIntervalSince1970))"
            case .unreadLine: "New"
            case .thread(let roomID): "thread " + session.title(of: roomID)
            case .pending(let pending): "pending " + pending.text
            }
        }
    }

    func testTheTimelineHasADayPillThreadCardsAtTheirCreationAndTheNewLine() async throws {
        let home = try await home()
        let general = home.timeline("general")
        let items = home.timelineItems("general", lineBefore: general[10].messageID, calendar: utc)
        XCTAssertEqual(names(items, in: home), ["day 1793059200", "ada", "bram", "sam", "chiara", "ada", "eunji", "bram",
                                               "thread Release 0.2", "chiara", "ada", "sam", "New", "eunji", "bram", "dev"])
        XCTAssertEqual(items.map(\.id).prefix(3), ["day-1793059200.0", "1793091600000", "1793091660000"])
        XCTAssertEqual(items[8].id, "thread-1793092125000")
        XCTAssertEqual(items[12].id, "unread")
    }

    func testAMessageContinuesItsAuthorsRunWithinFiveMinutes() async throws {
        let home = try await home()
        let items = home.timelineItems(PreviewFixtures.linkRoomID, lineBefore: nil, calendar: utc)
        XCTAssertEqual(names(items, in: home).filter { !$0.hasPrefix("day") && !$0.hasPrefix("thread") }, ["eunji", "ada", "sam", "sam", "sam+"])
        let random = home.timelineItems(PreviewFixtures.mediaRoomID, lineBefore: nil, calendar: utc)
        XCTAssertEqual(names(random, in: home).filter { !$0.hasPrefix("day") }, ["chiara", "bram", "chiara", "chiara+", "chiara+", "bram", "chiara", "sam"])
    }

    func testCountsAndRoomFacts() async throws {
        let home = try await home()
        XCTAssertEqual(home.mentionCount(in: "general"), 1, "Ada's @Sam, unread")
        XCTAssertEqual(home.mentionCount(in: "random"), 0)
        XCTAssertEqual(home.threadIDs(in: "general").map(home.title(of:)), ["Release 0.2"])
        XCTAssertEqual(home.roomDescription(home.threadIDs(in: "general")[0]), "Ship Friday, then freeze")
        XCTAssertNil(home.roomDescription("general"))
        XCTAssertTrue(home.isPrivate("ops"))
        XCTAssertFalse(home.isPrivate("general"))
    }

    func testMembersAreOnlineThenOfflineEachByName() async throws {
        let home = try await home()
        let sections = home.memberSections("general")
        XCTAssertEqual(sections.map(\.title), ["Online", "Offline"])
        XCTAssertEqual(sections.map { $0.people.map(\.userID) }, [["ada", "bram", "chiara", "eunji", "sam"], ["dev"]])
        XCTAssertEqual(["ada", "bram", "chiara", "dev", "nobody"].map { home.presence(of: $0)?.label ?? "none" },
                       ["Online", "Idle", "Do not disturb", "Offline", "none"])
        XCTAssertEqual(Presence(["status": "invisible"]), .offline)
        XCTAssertEqual(Presence(["status": "away"]), .online, "an unknown status shows as online")
    }

    func testAMessageSnapshotsDateEditAndMentions() async throws {
        let home = try await home()
        let general = home.timeline("general")
        XCTAssertEqual(general[0].date, Date(timeIntervalSince1970: 1_793_091_600))
        XCTAssertEqual(general.filter(\.isEdited).map(\.plainText), ["Pushed a fix for the paging floor. Older history now stops in the right place."])
        XCTAssertEqual(general.filter { $0.mentions("sam") }.map(\.mentionIDs), [["sam"]])
        XCTAssertEqual(general.filter { $0.prevRoomID != nil }.map(\.isEdited), [false], "a move is not an edit")
    }

    func testTheMediaViewerPagesTheRoomsLoadableImages() async throws {
        let home = try await home()
        XCTAssertEqual(home.mediaItems(in: PreviewFixtures.mediaRoomID).map { [$0.id, $0.name, $0.sender, $0.alt ?? "", $0.original?.absoluteString ?? ""] },
                       [["1793088180000#0", "dansk-pot.jpg", "Chiara", "A red enamel pot on a wooden table", "https://home.example/files/embed_1/s1"]])
    }
}
