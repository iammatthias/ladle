import XCTest
@testable import ApronKit

@MainActor
final class ThreadsTests: XCTestCase {
    private func plain(_ text: String) -> JSONValue { ["text": .string(text), "format": "plain"] }
    private func markdown(_ text: String) -> JSONValue { ["text": .string(text), "format": "markdown"] }

    func testAStartedThreadIsTitledFromTheFirstLineThatIsNotBlank() {
        XCTAssertEqual(ThreadStart.title(plain("\n  \nDeploy   the\tbuild  \nsecond line")), "Deploy the build")
        XCTAssertEqual(ThreadStart.title(plain(String(repeating: "a", count: 58) + " bcd")), String(repeating: "a", count: 58) + "…",
                       "59 code points kept, the space trimmed, then the ellipsis")
        XCTAssertEqual(ThreadStart.title(plain(String(repeating: "x", count: 60))), String(repeating: "x", count: 60))
        XCTAssertEqual(ThreadStart.title(plain("   ")), "Thread")
        XCTAssertEqual(ThreadStart.title(nil), "Thread")
        XCTAssertEqual(ThreadStart.title(markdown("**Ship** it")), "**Ship** it", "markdown is not stripped")
    }

    func testTheDescriptionQuotesTheMessageEscapingPlainText() {
        XCTAssertEqual(ThreadStart.description(plain("Ship *Friday*\n\n  then #freeze")), "> Ship \\*Friday\\*\n>\n> &#32;&#32;then \\#freeze")
        XCTAssertEqual(ThreadStart.description(markdown("Ship **Friday**\n- a")), "> Ship **Friday**\n> - a")
        XCTAssertNil(ThreadStart.description(plain(" \n ")))
        XCTAssertEqual(ThreadStart.escape("a.b\tc"), "a\\.b\tc")
        XCTAssertEqual(ThreadStart.escape("\tx"), "&#9;x")
    }

    func testALongDescriptionIsCutOnALineOrWordAndClosesItsFence() {
        let words = String(repeating: "word ", count: 120)
        let cut = ThreadStart.shortenMarkdown(words, 500)
        XCTAssertTrue(cut.hasSuffix("word…"), "cut at the last space, never mid-word")
        XCTAssertEqual(cut.unicodeScalars.count, 495)
        let lines = "intro\n```swift\n" + String(repeating: "let x = 1\n", count: 60)
        XCTAssertTrue(ThreadStart.shortenMarkdown(lines, 500).hasSuffix("let x = 1\n```\n\n…"), "the open fence is closed")
        XCTAssertEqual(ThreadStart.shortenMarkdown("short", 500), "short")
    }

    func testLastActiveIsFlooredToTheLargestUnit() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let ago = { (seconds: Double) in LastActive.words(now.addingTimeInterval(-seconds), now: now) }
        XCTAssertEqual(ago(59), "now")
        XCTAssertEqual(ago(60 * 59 + 59), "59m")
        XCTAssertEqual(ago(3600 * 23), "23h")
        XCTAssertEqual(ago(86_400 * 4 + 3600), "4d")
        XCTAssertEqual(ago(86_400 * 63), "9w")
        XCTAssertEqual(ago(86_400 * 7 * 52), "1y", "52 weeks is 364 days, which floors to 0 years: 1y")
        XCTAssertEqual(ago(86_400 * 733), "2y")
    }

    func testTheOpenRoomListsJoinedThreadsByActivityThenThreeOthers() {
        let entry = { (id: String, joined: Bool, activity: String?, news: Bool) in
            ThreadList.Entry(id: id, joined: joined, activity: activity.flatMap(LogID.init), hasNews: news)
        }
        let entries = [
            entry("a", true, "10", false), entry("b", true, "30", false), entry("c", true, nil, true), entry("d", true, "30", false),
            entry("o1", false, "50", false), entry("o2", false, "40", false), entry("o3", false, "20", false), entry("o4", false, "5", false),
        ]
        let open = ThreadList(entries, isOpenRoom: true, openThread: nil, othersFolded: false, allOthers: false)
        XCTAssertEqual(open.joined, ["b", "d", "a", "c"], "newest first, ties by room_id, unknown last")
        XCTAssertEqual([open.others, [String(open.othersCount), String(open.moreOthers)]], [["o1", "o2", "o3"], ["4", "1"]])
        let reading = ThreadList(entries, isOpenRoom: true, openThread: "o4", othersFolded: false, allOthers: false)
        XCTAssertEqual([reading.others, [String(reading.moreOthers)]], [["o1", "o2", "o3", "o4"], ["0"]], "the one read without joining always shows")
        XCTAssertEqual(ThreadList(entries, isOpenRoom: true, openThread: "o4", othersFolded: true, allOthers: false).others, ["o4"])
        XCTAssertEqual(ThreadList(entries, isOpenRoom: true, openThread: nil, othersFolded: false, allOthers: true).others.count, 4)

        let elsewhere = ThreadList(entries, isOpenRoom: false, openThread: nil, othersFolded: false, allOthers: false)
        XCTAssertEqual([elsewhere.joined, elsewhere.others], [["c"], []], "another room shows only its joined threads with news")
    }

    func testTheFixturesThreadsUnderTheOpenRoomAndElsewhere() async throws {
        let store = await PreviewFixtures.makeStore()
        let home = try XCTUnwrap(store.session(for: PreviewFixtures.homeID))
        let general = try XCTUnwrap(home.roomTree.first { $0.roomID == "general" })
        let open = home.threadList(of: general, open: "general")
        XCTAssertEqual(open.joined.map(home.title(of:)), ["Release 0.2", "Load test", "Origin check", "Docs", "Passkeys", "Untitled", "Archive 2025"])
        XCTAssertEqual(open.others.map(home.title(of:)), ["Benchmarks", "Hiring", "2024 offsite"])
        XCTAssertEqual(open.moreOthers, 1)
        let now = PreviewFixtures.now
        XCTAssertEqual(open.others.compactMap(home.lastActive(of:)).map { LastActive.words($0, now: now) }, ["4d", "9w", "2y"])
        XCTAssertEqual(home.threadList(of: general, open: PreviewFixtures.releaseThreadID).joined.count, 7, "a thread open is its room open")
        XCTAssertEqual(home.threadList(of: general, open: "random").joined.map(home.title(of:)), ["Release 0.2"], "only the thread with news")
        XCTAssertEqual(home.threadList(of: general, open: nil).others, [])

        XCTAssertTrue(home.isUntitled(PreviewFixtures.untitledThreadID))
        XCTAssertFalse(home.isUntitled("general"))
        XCTAssertEqual(home.title(of: "nowhere"), "nowhere", "a room without a record is its room_id")
        XCTAssertEqual(home.replyWords(in: PreviewFixtures.releaseThreadID), "4 replies")
        XCTAssertNil(home.replyWords(in: "general"), "a room has no replies line")
    }
}
