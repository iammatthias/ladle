@testable import ApronKit
import XCTest

/// apron-web's message-log.test.ts, in UTC and en_US. Times carry the U+202F before AM/PM that
/// ICU writes. The web's IDs that carry no time (`'old'`, `'a'`) are IDs past the last date a
/// JavaScript `Date` holds, which carry none there either.
final class MessageLogTests: XCTestCase {
    private let names = ["ada": "Ada Lovelace", "ben": "Ben", "cy": "Cy"]
    private lazy var nameOf: (MessageSnapshot) -> String = { [names] in names[$0.from.userID] ?? $0.from.userID }
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }()
    /// 30 Oct 2026, 18:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_793_383_200)

    /// An ID that carries no time.
    private func timeless(_ n: Int) -> String { String(8_640_000_000_000_000 + n) }

    /// A message at `minute` past 14:00 UTC on 30 Oct 2026, a markdown body unless `body` says otherwise.
    private func at(_ minute: Int, _ from: String, _ text: String, id: String? = nil, logID: String? = nil,
                    body: JSONValue? = nil, replyTo: String? = nil, deleted: Bool? = nil) -> MessageSnapshot {
        let id = id ?? String(1_793_368_800_000 + minute * 60_000)
        return MessageSnapshot(messageID: LogID(id)!, logID: LogID(logID ?? id)!, roomID: "ops", from: UserObject(["user_id": .string(from)])!,
                               body: body ?? ["text": .string(text), "format": "markdown"], replyTo: replyTo.flatMap { LogID($0) }, deleted: deleted)
    }

    private func log(_ messages: [MessageSnapshot], lookup: @escaping (LogID) -> MessageSnapshot? = { _ in nil }, now: Date? = nil,
                     reactions: @escaping (MessageSnapshot) -> [MessageLog.Reaction]? = { _ in nil }, order: [String]? = nil) -> String {
        MessageLog.markdown(messages, options: .init(nameOf: nameOf, lookup: lookup, now: now ?? self.now, reactions: reactions,
                                                     order: order?.map { LogID($0)! }, calendar: calendar))
    }

    func testQuotesEachSendersRunUnderTheirNameAndTimeDatesTheFirstAndSaysWhatAReplyAnswers() {
        let deploy = at(2, "ada", "Deploy is green, rolling to **prod** now.")
        let pods = at(4, "ben", "Worker pods are restarting in a loop.", replyTo: deploy.messageID.text)
        let crash = at(5, "ben", "Crash is in the new queue client:\n\n```\nTypeError: conn is undefined\n```")
        let rollback = at(20, "cy", "Rolled back worker to 1.8.3.", replyTo: pods.messageID.text)
        let thanks = at(31, "ada", "", body: ["text": "Thanks both — retro at 16:00.", "embeds": [["kind": "og", "url": "https://meet.example/retro", "og": ["title": "Retro"]]]])
        XCTAssertEqual(log([deploy, pods, crash, rollback, thanks]), [
            "> **Ada Lovelace** · Friday, Oct 30, 2026 at 2:02\u{202F}PM",
            ">",
            "> Deploy is green, rolling to **prod** now.",
            "",
            "> **Ben** · 2:04\u{202F}PM",
            ">",
            "> > ↪ **Ada Lovelace**: Deploy is green, rolling to prod now.",
            ">",
            "> Worker pods are restarting in a loop.",
            ">",
            "> Crash is in the new queue client:",
            ">",
            "> ```",
            "> TypeError: conn is undefined",
            "> ```",
            "",
            "> **Cy** · 2:20\u{202F}PM",
            ">",
            "> > ↪ **Ben**: Worker pods are restarting in a loop.",
            ">",
            "> Rolled back worker to 1.8.3.",
            "",
            "> **Ada Lovelace** · 2:31\u{202F}PM",
            ">",
            "> Thanks both — retro at 16:00.",
        ].joined(separator: "\n"))
    }

    func testNamesAReplysTargetFromOutsideTheLogWhenItCanSaysSoWhenItCantAndKeepsTheSnippetsMarkdownInert() {
        let earlier = at(0, "cy", "Who owns the *queue* client?", id: timeless(1))
        let answer = at(1, "ben", "I do.", id: timeless(2), replyTo: timeless(1))
        let orphan = at(2, "ada", "Agreed.", id: timeless(3), replyTo: timeless(4))
        let echo = at(3, "cy", "It’s mine.", id: timeless(6), replyTo: timeless(5))
        let plain = at(3, "ben", "", id: timeless(5), body: ["text": "run `make` _now_", "format": "plain"])
        let lookup = { [earlier] (id: LogID) in id == earlier.messageID ? earlier : nil }
        XCTAssertEqual(log([answer, orphan, plain, echo], lookup: lookup), [
            "> **Ben**", ">", "> > ↪ **Cy**: Who owns the queue client?", ">", "> I do.", "",
            "> **Ada Lovelace**", ">", "> > ↪ _(an earlier message)_", ">", "> Agreed.", "",
            "> **Ben**", ">", "> run `make` _now_", "",
            "> **Cy**", ">", "> > ↪ **Ben**: run \\`make\\` \\_now\\_", ">", "> It’s mine.",
        ].joined(separator: "\n"))
    }

    func testEndsAReplysSnippetInAnEllipsisWhereItLeavesLaterLinesOutAndLeavesAMidLineArrowAsWritten() {
        let plan = at(0, "ada", "Two options:\n\n- popup -> passkey\n- copy a code", id: timeless(1))
        let pick = at(10, "ben", "The first.", id: timeless(2), replyTo: timeless(1))
        let arrow = at(11, "cy", "popup -> passkey", id: timeless(3))
        let agree = at(20, "ada", "Yes.", id: timeless(4), replyTo: timeless(3))
        let text = log([plan, pick, arrow, agree])
        XCTAssertTrue(text.contains("> > ↪ **Ada Lovelace**: Two options:…\n"), text)
        XCTAssertTrue(text.contains("> > ↪ **Cy**: popup -> passkey\n"), text)
    }

    func testNotesDeletedAndAttachmentOnlyMessagesAndKeepsANamesMarkdownInert() {
        let upload = at(0, "ada", "", id: timeless(1), body: ["embeds": [["kind": "upload", "url": "https://cdn.example/a.pdf", "title": "a.pdf"]]])
        let gone = at(0, "ben", "", id: timeless(2), body: .null, deleted: true)
        let starry = at(0, "*star*", "hi", id: timeless(3))
        XCTAssertEqual(log([upload, gone, starry]), "> **Ada Lovelace**\n>\n> _(attachment)_\n\n> **Ben**\n>\n> _(deleted)_\n\n> **\\*star\\***\n>\n> hi")
    }

    func testSaysWhereMessagesBetweenTwoAreNotLoaded() {
        let one = at(0, "ada", "One.")
        let two = at(1, "ada", "Two.")
        let five = at(5, "ada", "Five.")
        let hole = LogSpan(LogID(at(2, "ada", "").messageID.text)!, LogID(at(4, "ada", "").messageID.text)!)
        let options = MessageLog.Options(nameOf: nameOf, now: now, order: [one, two, five].map(\.messageID), holes: [hole], calendar: calendar)
        XCTAssertEqual(MessageLog.markdown([one, two, five], options: options), [
            "> **Ada Lovelace** · Friday, Oct 30, 2026 at 2:00\u{202F}PM", ">", "> One.", ">", "> Two.", "",
            "_(messages not loaded)_", "",
            "> **Ada Lovelace** · 2:05\u{202F}PM", ">", "> Five.",
        ].joined(separator: "\n"), "a hole between two picked messages breaks the run, however many it holds")
        XCTAssertEqual(MessageLog.markdown([one, five], options: options), [
            "> **Ada Lovelace** · Friday, Oct 30, 2026 at 2:00\u{202F}PM", ">", "> One.", "",
            "_(1 message omitted, and more not loaded)_", "",
            "> **Ada Lovelace** · 2:05\u{202F}PM", ">", "> Five.",
        ].joined(separator: "\n"))
    }

    func testNotesAnEmptyMessageAndAReplyToADeletedOne() {
        let gone = at(0, "ben", "", id: timeless(1), body: .null, deleted: true)
        let reply = at(1, "ada", "What did it say?", id: timeless(2), replyTo: timeless(1))
        let empty = at(2, "cy", "", id: timeless(3), body: ["text": "  "])
        XCTAssertEqual(log([reply, empty], lookup: { [gone] in $0 == gone.messageID ? gone : nil }),
                       "> **Ada Lovelace**\n>\n> > ↪ _(a deleted message)_\n>\n> What did it say?\n\n> **Cy**\n>\n> _(empty)_")
    }

    func testListsAMessagesReactionsAfterItsSendersNameHeadingItAndTheMessageAfterOnTheirOwn() {
        let first = at(0, "ada", "One.")
        let second = at(1, "ada", "Two.")
        let third = at(2, "ada", "Three.")
        let fourth = at(3, "ada", "Four.")
        let reactions = { [second, third] (message: MessageSnapshot) -> [MessageLog.Reaction]? in
            if message.messageID == second.messageID {
                return [
                    .init(emoji: "👍", names: ["Ben", "Cy"], count: 2),
                    .init(emoji: "👎", names: ["Ada Lovelace"], count: 1),
                    .init(emoji: "🎉", names: [], count: 0),
                    .init(emoji: ":party_parrot:", names: ["Ben"], count: 3),
                ]
            }
            return message.messageID == third.messageID ? [.init(emoji: "👀", names: [], count: 2)] : nil
        }
        XCTAssertEqual(log([first, second, third, fourth], reactions: reactions), [
            "> **Ada Lovelace** · Friday, Oct 30, 2026 at 2:00\u{202F}PM", ">", "> One.", "",
            "> **Ada Lovelace** · 2:01\u{202F}PM (👍 from Ben, Cy; 👎 from Ada Lovelace; :party\\_parrot: from Ben, 2 more)", ">", "> Two.", "",
            "> **Ada Lovelace** · 2:02\u{202F}PM (👀 from 2 people)", ">", "> Three.", "",
            "> **Ada Lovelace** · 2:03\u{202F}PM", ">", "> Four.",
        ].joined(separator: "\n"))
    }

    func testSaysHowManyMessagesAGapLeavesOutAndHeadsTheMessageAfterIt() {
        let order = (1 ... 6).map { at($0, "ada", "").messageID.text }
        let one = at(1, "ada", "One.")
        let three = at(3, "ada", "Three.")
        let four = at(4, "ada", "Four.")
        let six = at(6, "ada", "Six.")
        XCTAssertEqual(log([one, three, four, six], order: order), [
            "> **Ada Lovelace** · Friday, Oct 30, 2026 at 2:01\u{202F}PM", ">", "> One.", "",
            "_(1 message omitted)_", "",
            "> **Ada Lovelace** · 2:03\u{202F}PM", ">", "> Three.", ">", "> Four.", "",
            "_(1 message omitted)_", "",
            "> **Ada Lovelace** · 2:06\u{202F}PM", ">", "> Six.",
        ].joined(separator: "\n"))
        XCTAssertTrue(log([one, four], order: order).contains("\n\n_(2 messages omitted)_\n\n"))
        // Without `order`, or for a message it doesn't list, nothing is said to be left out.
        XCTAssertFalse(log([one, six]).contains("omitted"))
        XCTAssertFalse(log([one, at(0, "ada", "Elsewhere.", id: timeless(1))], order: order).contains("omitted"))
    }

    func testKeepsASendersMessagesAFewMinutesApartInOneQuote() {
        let first = at(0, "ada", "One.")
        let second = at(2, "ada", "Two,\nstill two.")
        XCTAssertEqual(log([first, second]), "> **Ada Lovelace** · Friday, Oct 30, 2026 at 2:00\u{202F}PM\n>\n> One.\n>\n> Two,\n> still two.")
    }

    func testDatesTheFirstMessageInFullAndEachNewDayAfterWithTheYearOnlyWhenItIsntThisOne() {
        let late = at(0, "ada", "Night.")
        let next = at(0, "ada", "", id: "1793437200000", body: ["text": "Morning."])
        let thisYear = log([late, next])
        XCTAssertTrue(thisYear.contains("> **Ada Lovelace** · Friday, Oct 30, 2026 at 2:00\u{202F}PM"), thisYear)
        XCTAssertTrue(thisYear.contains("> **Ada Lovelace** · Saturday, Oct 31 at 9:00\u{202F}AM"), thisYear)
        let lastYear = log([late, next], now: Date(timeIntervalSince1970: 1_798_761_600))
        XCTAssertTrue(lastYear.contains("> **Ada Lovelace** · Saturday, Oct 31, 2026 at 9:00\u{202F}AM"), lastYear)
    }

    func testShowsEachMessageOnceAsItsLatestSnapshotWhereItFirstCame() {
        let first = at(0, "ada", "Deploy is gren", id: timeless(1), logID: "10")
        let other = at(1, "ben", "On it.", id: timeless(2), logID: "11")
        var edited = first
        edited.logID = LogID("12")!
        edited.body = ["text": "Deploy is green"]
        var stale = first
        stale.logID = LogID("9")!
        stale.body = ["text": "Deploy"]
        XCTAssertEqual(log([first, other, edited, stale]), "> **Ada Lovelace**\n>\n> Deploy is green\n\n> **Ben**\n>\n> On it.")
    }

    func testAddsUploadedImagesAsMarkdownImagesAndLeavesOutUploadsStillGoingOtherFilesAndLinkPreviews() {
        func image(_ url: String, _ title: String = "image.webp") -> JSONValue {
            ["kind": "upload", "title": .string(title), "url": .string(url), "og": ["title": .string(title), "image": ["url": .string(url), "type": "image/webp"]]]
        }
        let card: JSONValue = ["kind": "og", "url": "https://example.com", "og": ["title": "Example", "image": ["url": "https://example.com/card.png"]]]
        let shot = at(0, "cy", "", id: timeless(1), body: ["text": "stateless components ftw", "embeds": [image("https://media.example/f/a"), card]])
        let alone = at(0, "cy", "", id: timeless(2), body: ["embeds": [image("https://media.example/f/(b)", "a [b]\nc")]])
        let pending = at(0, "cy", "", id: timeless(3), body: ["embeds": [["kind": "upload", "title": "image.webp"], ["kind": "upload", "title": "notes.pdf", "url": "https://media.example/f/c"]]])
        XCTAssertEqual(log([shot, alone, pending]), [
            "> **Cy**", ">", "> stateless components ftw", ">", "> ![image.webp](https://media.example/f/a)", "",
            "> **Cy**", ">", "> ![a \\[b\\] c](https://media.example/f/%28b%29)", "",
            "> **Cy**", ">", "> _(attachment)_",
        ].joined(separator: "\n"))
    }

    func testIsEmptyForNoMessages() {
        XCTAssertEqual(log([]), "")
    }
}
