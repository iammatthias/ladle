import XCTest
@testable import ApronKit

@MainActor
final class MessageRowModelTests: XCTestCase {
    private func row(_ room: String, _ id: String, in store: SessionStore) throws -> MessageRowModel {
        let home = try XCTUnwrap(store.session(for: PreviewFixtures.homeID))
        let message = try XCTUnwrap(home.timeline(room).first { $0.messageID.text == id })
        return MessageRowModel(message, in: home, sessions: store.liveSession(for:))
    }

    /// The row's spoken text with its time, which follows the test machine's locale, as TIME.
    private func spoken(_ row: MessageRowModel, reminderDue: Date? = nil, now: Date = .now) -> String {
        row.spoken(reminderDue: reminderDue, now: now).replacingOccurrences(of: row.message.date.formatted(date: .omitted, time: .shortened), with: "TIME")
    }

    func testAMentionOfYouIsMarkedAndSpoken() async throws {
        let store = await PreviewFixtures.makeStore()
        let mention = try row("general", "1793092500000", in: store)
        XCTAssertTrue(mention.mentionsYou)
        let chips = mention.text.runs.compactMap { run in run[MentionKey.self].map { "\(String(mention.text[run.range].characters)) \($0.userID) \($0.isYou)" } }
        XCTAssertEqual(chips, ["@Sam sam true"])
        XCTAssertEqual(spoken(mention), "Eun-ji, announce, mentions you, @Sam can you review the icon PR before then? It's small, mostly the ladle glyph at 20 pt., Link, The ladle glyph at 20 pt, TIME")
        XCTAssertFalse(try row("general", "1793091600000", in: store).mentionsYou)
    }

    func testAMentionIsMarkedByNameOrIdOutsideLinks() {
        let text = MessageText.attributed(["text": "@Ada and @bram, not [@Ada](https://example.com)", "format": "markdown"],
                                          mentions: ["ada": "Ada", "bram": "Bram"], you: "bram")
        let chips = text.runs.compactMap { run in run[MentionKey.self].map { "\(String(text[run.range].characters)) \($0.isYou)" } }
        XCTAssertEqual(chips, ["@Ada false", "@bram true"])
    }

    func testACardHidesTheSendersPreviewOfItsPlace() async throws {
        let store = await PreviewFixtures.makeStore()
        let notes = try row(PreviewFixtures.linkCardRoomID, "1793090580000", in: store)
        XCTAssertEqual(notes.cards.map(\.roomTitle), ["general"])
        XCTAssertEqual(notes.embeds.map(\.index), [], "the link embed for the same message is hidden")
        XCTAssertEqual(notes.message.embedList.count, 1)
        let places = try row(PreviewFixtures.linkCardRoomID, "1793090640000", in: store)
        XCTAssertEqual(spoken(places), "Sam, Checklist is in apron:?room=1793092125000, and the cert note in apron:?room=ops&message=1793074800000, Thread Release 0.2, 3 members, Room ops, private, 2 members, TIME")
    }

    func testAFetchedPreviewTakesTheLinkEmbedsPlaceOrGoesUnderTheEmbeds() async throws {
        let store = await PreviewFixtures.makeStore()
        let checklist = try row("general", "1793092560000", in: store)
        XCTAssertEqual(checklist.unfurl?.absoluteString, "https://git.example/ladle/wiki/Release-0.2")
        XCTAssertNil(checklist.unfurledEmbed, "a link in the text, with no embed for it")
        let described = try row("general", "1793092500000", in: store)
        XCTAssertNil(described.unfurl, "an embed with the server's og is the preview")
        XCTAssertEqual(described.embeds.map(\.index), [0])
        let poll = try row("general", "1793092800000", in: store)
        XCTAssertEqual(spoken(poll), "Dev, bot, Load test plan for Friday, moved from ops, Poll, TIME")
    }

    func testTheSpokenTextReadsTheReminderReplyEditAndReactions() async throws {
        let store = await PreviewFixtures.makeStore()
        let edited = try row("general", "1793092080000", in: store)
        XCTAssertEqual(spoken(edited, reminderDue: Date(timeIntervalSince1970: 1_793_103_600), now: Date(timeIntervalSince1970: 1_793_100_000)),
                       "Due in 1 hr, Bram, Pushed a fix for the paging floor. Older history now stops in the right place., edited, TIME, ❤️ 2")
        XCTAssertEqual(spoken(try row("general", "1793092440000", in: store)), "Sam, replying to a deleted message, I'll cut the build after lunch., TIME, 👍 1")
        XCTAssertEqual(spoken(try row("kitchen", "1793083980000", in: store)),
                       "Bram, Keys in code stay text: `Squirrel in a hat`. Out of it, two at once Squirrel in a hatSquirrel in a hat, TIME")
        XCTAssertEqual(spoken(try row("kitchen", "1793083800000", in: store)),
                       "Ada Okafor, admin, Shipped the new glaze :apron: :partyparrot:, TIME, :apron: 1, :partyparrot: 2, :retired: 1, 👍 1")
    }
}
