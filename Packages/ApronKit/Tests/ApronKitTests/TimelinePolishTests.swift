import Foundation
import XCTest
@testable import ApronKit

final class TimelinePolishTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ text: String) -> Date { try! Date(text, strategy: .iso8601) }

    func testADayPillSaysTodayYesterdayOrTheShortDayWithTheYearWhenNotThisOnes() {
        let now = date("2026-10-31T12:00:00Z")
        let words = ["2026-10-31T00:30:00Z", "2026-10-30T23:59:00Z", "2026-10-26T09:00:00Z", "2025-12-24T09:00:00Z"].map {
            DayLabel.text(date($0), now: now, calendar: utc, locale: Locale(identifier: "en_US"))
        }
        XCTAssertEqual(words, ["Today", "Yesterday", "Mon, Oct 26", "Wed, Dec 24, 2025"])
    }

    private func message(_ id: String, from user: String = "bob", log: String? = nil, mentions: [String] = []) -> MessageSnapshot {
        MessageSnapshot(messageID: LogID(id)!, logID: LogID(log ?? id)!, roomID: "general", from: UserObject(["user_id": .string(user)])!,
                        body: ["text": "hi", "mentions": .array(mentions.map(JSONValue.string))])
    }

    func testTheFloatingDayIsTheFirstMessageInViewsUnlessItsPillShowsAboveIt() {
        let monday = message("1793091600000"), tuesday = message("1793178000000")
        let items: [TimelineItem] = [.day(monday.date), .message(monday, continues: false), .thread(roomID: "t"),
                                     .day(tuesday.date), .message(tuesday, continues: false)]
        let ids = items.map(\.id)
        let days = [[ids[1], ids[2]], [ids[0], ids[1]], [ids[2], ids[3], ids[4]], [ids[2], ids[4]], []].map {
            FloatingDay.day(of: items, visible: Set($0))
        }
        XCTAssertEqual(days, [monday.date, nil, nil, tuesday.date, nil])
    }

    func testAMentionPulsesOnceAsItArrivesAndNeverForWhatTheRoomHeldWhenShown() {
        var pulse = MentionPulse()
        let history = [message("100", mentions: ["ada"]), message("101")]
        XCTAssertEqual(pulse.arrivals(in: history, latest: LogID("102"), you: "ada"), [], "shown: history never pulses")

        let late = message("102", mentions: ["ada"])
        XCTAssertEqual(pulse.arrivals(in: history + [late], latest: nil, you: "ada"), [],
                       "at the watermark, the room's latest when shown, it is history too")

        let live = message("103", mentions: ["ada"]), own = message("104", from: "ada", mentions: ["ada"]), other = message("105", mentions: ["bob"])
        let now = history + [late, live, own, other]
        XCTAssertEqual(pulse.arrivals(in: now, latest: nil, you: "ada"), [LogID("103")!], "not your own, nor someone else's mention")
        XCTAssertEqual(pulse.arrivals(in: now, latest: nil, you: "ada"), [], "once")

        let editedIn = message("101", log: "106", mentions: ["ada"])
        let editedAgain = message("103", log: "107", mentions: ["ada"])
        XCTAssertEqual(pulse.arrivals(in: [history[0], editedIn, late, editedAgain, own, other], latest: nil, you: "ada"), [LogID("101")!],
                       "an edit that adds you pulses; one of a message already mentioning you does not")
    }
}
