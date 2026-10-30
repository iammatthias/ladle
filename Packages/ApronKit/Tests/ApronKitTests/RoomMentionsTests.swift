import XCTest
@testable import ApronKit

final class RoomMentionsTests: XCTestCase {
    private let rooms = ["general": "general", "design": "Design review", "1793092125000": "Release 0.2", "ops.alerts": "Alerts"]

    private func chips(_ text: String, format: String = "plain") -> [(text: String, id: String, link: String?)] {
        let out = MessageText.attributed(["text": .string(text), "format": .string(format)], rooms: { self.rooms[$0] })
        return out.runs.compactMap { run in
            run[RoomReferenceKey.self].map { (String(out[run.range].characters), $0, run.link?.absoluteString) }
        }
    }

    private func shown(_ text: String, format: String = "plain") -> String {
        String(MessageText.attributed(["text": .string(text), "format": .string(format)], rooms: { self.rooms[$0] }).characters)
    }

    func testAKnownRoomShowsAsItsTitleAndLinksToIt() {
        let found = chips("see #general and #1793092125000.")
        XCTAssertEqual(found.map(\.text), ["#\u{2068}general\u{2069}", "#\u{2068}Release 0.2\u{2069}"])
        XCTAssertEqual(found.map(\.id), ["general", "1793092125000"])
        XCTAssertEqual(found.map(\.link), ["apron:?room=general", "apron:?room=1793092125000"])
        XCTAssertEqual(shown("see #general and #1793092125000."), "see #\u{2068}general\u{2069} and #\u{2068}Release 0.2\u{2069}.",
                       "the trailing dot is not part of the id")
    }

    func testAnUnknownRoomAndAHashAfterALetterStayText() {
        XCTAssertEqual(shown("#doesnotexist and a#general and C#"), "#doesnotexist and a#general and C#")
        XCTAssertTrue(chips("#doesnotexist").isEmpty)
    }

    func testTheLongestIdIsRead() {
        XCTAssertEqual(chips("#ops.alerts!").map(\.id), ["ops.alerts"])
        XCTAssertTrue(chips("#general-old").isEmpty, "a longer id the client doesn't know")
    }

    func testCodeAndLinksKeepTheirText() {
        XCTAssertTrue(chips("`#general` [#general](https://example.com/x)", format: "markdown").isEmpty)
        XCTAssertTrue(chips("https://link.apron.chat/#room=general").isEmpty, "a fragment inside a bare link")
        XCTAssertEqual(chips("**#general**", format: "markdown").map(\.id), ["general"])
    }

    func testTheComposerQueryIsTheHashWordBeingTyped() {
        XCTAssertEqual(RoomMentions.query(in: "see #gen"), "gen")
        XCTAssertEqual(RoomMentions.query(in: "#ops.al"), "ops.al")
        XCTAssertEqual(RoomMentions.query(in: "line\n#des"), "des")
        XCTAssertNil(RoomMentions.query(in: "see #"), "nothing typed after the #")
        XCTAssertNil(RoomMentions.query(in: "C#"), "not after a letter")
        XCTAssertNil(RoomMentions.query(in: "#general "), "finished")
        XCTAssertNil(RoomMentions.query(in: "#a/b"))
    }

    func testSearchRanksExactThenPrefixThenContains() {
        let list = [
            RoomSuggestion(id: "design", title: "design"), RoomSuggestion(id: "1793091825000", title: "Icon sketches", isThread: true),
            RoomSuggestion(id: "ops", title: "ops", isPrivate: true), RoomSuggestion(id: "redesign", title: "redesign"),
            RoomSuggestion(id: "des", title: "Zed"),
        ]
        XCTAssertEqual(RoomMentions.search(list, "des").map(\.id), ["des", "design", "redesign"])
        XCTAssertEqual(RoomMentions.search(list, "ICON").map(\.id), ["1793091825000"], "by title, any case")
        XCTAssertEqual(RoomMentions.search(list, "1793").map(\.id), ["1793091825000"], "by id")
        let many = (0 ..< 12).map { RoomSuggestion(id: "r\($0)", title: "room \($0)") }
        XCTAssertEqual(RoomMentions.search(many, "room").count, 8)
    }

    func testPickingInsertsTheIdAndASpace() {
        XCTAssertEqual(RoomMentions.insert("1793092125000", into: "see #rel"), "see #1793092125000 ")
        XCTAssertEqual(RoomMentions.insert("general", into: "#gen"), "#general ")
        XCTAssertEqual(RoomMentions.insert("general", into: "no query"), "no query")
    }

    @MainActor
    func testTheSessionOffersEveryRoomItHolds() async throws {
        let store = await PreviewFixtures.makeStore()
        let home = try XCTUnwrap(store.session(for: PreviewFixtures.homeID))
        XCTAssertEqual(RoomMentions.search(home.roomSuggestions, "s").map(\.title), ["design", "Icon sketches", "ops", "Release 0.2"], "each holds an s: by title")
        XCTAssertEqual(home.referencedTitle("general"), "general")
        XCTAssertNil(home.referencedTitle("doesnotexist"))
    }
}
