import XCTest
@testable import ApronKit

/// apron-web's `shortcuts.test.ts`, `message-focus.test.ts`, `room-steps.test.ts` and
/// `selection.svelte.test.ts`'s extend case, over Ladle's table and rows.
final class KeyboardFocusTests: XCTestCase {
    private func keys(_ label: String, in scope: Shortcuts.Scope? = nil) -> [[String]]? {
        Shortcuts.all.first { $0.label == label && (scope == nil || $0.scope == scope) }?.chords.map(\.written)
    }

    func testTheTableWritesKeysAsAnIPadKeyboardMarksThem() {
        XCTAssertEqual(keys("Search local history"), [["⌘", "F"]])
        XCTAssertEqual(keys("Go to a room or thread"), [["⌘", "K"]])
        XCTAssertEqual(keys("Move a room up or down"), [["⌥", "↑"], ["⌥", "↓"]])
        XCTAssertEqual(keys("Previous or next room, past threads"), [["⌥", "⇧", "↑"], ["⌥", "⇧", "↓"]])
        XCTAssertEqual(keys("New line"), [["⇧", "Return"]])
        XCTAssertEqual(Shortcuts.Chord(.up, [.option, .shift]).spoken, "Option Shift Up Arrow")
    }

    func testTheSheetNamesHowToShowItselfFirstAndEveryEntryOnceWithKeys() {
        let groups = Shortcuts.groups
        XCTAssertEqual(groups.map(\.group), [.general, .composer, .messages, .rooms])
        XCTAssertEqual(groups[0].entries[0].label, "Show keyboard shortcuts")
        XCTAssertEqual(groups[0].entries[0].chords.map(\.written), [["⌘", "/"]])
        for (_, entries) in groups {
            XCTAssertFalse(entries.isEmpty)
            XCTAssertEqual(Set(entries.map(\.label)).count, entries.count)
            for entry in entries { XCTAssertFalse(entry.keys.isEmpty) }
        }
    }

    func testEachChordMeansOneThingWhereItIsTaken() {
        XCTAssertEqual(Shortcuts.action(for: .init(.character("r")), in: .message), .reply)
        XCTAssertEqual(Shortcuts.action(for: .init(.character("e")), in: .message), .edit)
        XCTAssertEqual(Shortcuts.action(for: .init(.up), in: .message), .message(.previous))
        XCTAssertEqual(Shortcuts.action(for: .init(.pageDown), in: .message), .message(.pageDown))
        XCTAssertEqual(Shortcuts.action(for: .init(.up, .shift), in: .message), .extendSelection(up: true))
        XCTAssertEqual(Shortcuts.action(for: .init(.up), in: .composer), .toMessages)
        XCTAssertEqual(Shortcuts.action(for: .init(.down, .option), in: .anywhere), .room(step: 1, pastThreads: false))
        XCTAssertEqual(Shortcuts.action(for: .init(.down, .option), in: .roomRow), .moveRoom(step: 1))
        XCTAssertNil(Shortcuts.action(for: .init(.character("r"), .command), in: .message), "r with ⌘ is not Reply")
        XCTAssertNil(Shortcuts.action(for: .init(.enter), in: .message))
        for scope in [Shortcuts.Scope.anywhere, .composer, .message, .roomRow, .goTo] {
            let chords = Shortcuts.entries(in: scope).flatMap(\.chords)
            XCTAssertEqual(Set(chords).count, chords.count, "a chord bound twice in \(scope)")
        }
    }

    // MARK: Messages

    private let stops = ["0", "1", "2", "3", "4", "5"]

    func testStepsOneUpOrDownToTheEndsOrAPageAndStopsPastAnEnd() {
        XCTAssertEqual(TimelineKeys.step(.previous, from: "3", in: stops), .row("2"))
        XCTAssertEqual(TimelineKeys.step(.next, from: "3", in: stops), .row("4"))
        XCTAssertEqual(TimelineKeys.step(.first, from: "3", in: stops), .row("0"))
        XCTAssertEqual(TimelineKeys.step(.last, from: "3", in: stops), .row("5"))
        XCTAssertEqual(TimelineKeys.step(.pageUp, from: "3", in: stops, perPage: 2), .row("1"))
        XCTAssertEqual(TimelineKeys.step(.pageUp, from: "1", in: stops, perPage: 4), .row("0"))
        XCTAssertEqual(TimelineKeys.step(.pageDown, from: "3", in: stops, perPage: 4), .row("5"))
        // Past the oldest (older ones to load) and the newest (the composer next).
        XCTAssertEqual(TimelineKeys.step(.previous, from: "0", in: stops), .older)
        XCTAssertEqual(TimelineKeys.step(.first, from: "0", in: stops), .older)
        XCTAssertEqual(TimelineKeys.step(.pageUp, from: "0", in: stops, perPage: 3), .older)
        XCTAssertEqual(TimelineKeys.step(.next, from: "5", in: stops), .composer)
        XCTAssertEqual(TimelineKeys.step(.last, from: "5", in: stops), .composer)
        // From the composer (nothing on a row), the newest.
        XCTAssertEqual(TimelineKeys.step(.previous, from: nil, in: stops), .row("5"))
        XCTAssertEqual(TimelineKeys.step(.previous, from: nil, in: []), .composer)
    }

    func testStopsAtMessagesThreadCardsAndGapsNotAtLinesBetween() {
        let message = MessageSnapshot(messageID: LogID("10")!, logID: LogID("10")!, roomID: "general",
                                      from: UserObject(["user_id": "ada"])!, body: ["text": "hi"], deleted: nil)
        let hole = LogSpan(LogID("20")!, LogID("30")!)
        let items: [TimelineItem] = [.day(.distantPast), .message(message, continues: false, pending: nil), .unreadLine,
                                     .thread(roomID: "t-plan"), .gap(hole)]
        XCTAssertEqual(TimelineKeys.stops(items), ["10", "thread-t-plan", "gap-20"])
    }

    func testShiftArrowsPickFromTheAnchorAndGiveThemUpSteppingBack() {
        let order = ["1", "2", "3", "4", "5"].map { LogID($0)! }
        var selection = MessageSelection(roomID: "general", first: order[2])
        selection.extend(from: order[2], to: order[1], order: order)
        selection.extend(from: order[2], to: order[0], order: order)
        XCTAssertEqual(selection.ids, Array(order[0 ... 2]))
        selection.extend(from: order[2], to: order[1], order: order)
        XCTAssertEqual(selection.ids, Array(order[1 ... 2]))
        selection.extend(from: order[2], to: order[4], order: order)
        XCTAssertEqual(selection.ids, Array(order[2 ... 4]))
        XCTAssertEqual(selection.last, order[4])
        XCTAssertEqual(TimelineKeys.extending(from: order[0], up: true, among: order), nil)
        XCTAssertEqual(TimelineKeys.extending(from: order[0], up: false, among: order), order[1])
    }

    // MARK: Rooms

    private func rows(_ ids: String...) -> [RoomSteps.Row] {
        ids.map { RoomSteps.Row($0, isRoom: !$0.hasPrefix("t-")) }
    }

    func testStepsToTheRowAfterOrBeforeTheOpenOneStoppingAtTheEnds() {
        let list = rows("general", "eng", "t-plan", "random")
        XCTAssertEqual(RoomSteps.next(list, open: "eng", step: 1), "t-plan")
        XCTAssertEqual(RoomSteps.next(list, open: "eng", step: -1), "general")
        XCTAssertNil(RoomSteps.next(rows("only"), open: "only", step: 1))
        XCTAssertNil(RoomSteps.next(rows("a", "b"), open: "a", step: -1))
    }

    func testWithNoRowOpenStartsAtTheFirstOrTheLast() {
        let list = rows("general", "random")
        XCTAssertEqual(RoomSteps.next(list, open: nil, step: 1), "general")
        XCTAssertEqual(RoomSteps.next(list, open: nil, step: -1), "random")
        XCTAssertEqual(RoomSteps.next(list, open: "gone", step: 1), "general")
    }

    func testPastThreadsGoesToTheNearestRoomThatWay() {
        let list = rows("general", "t-cert", "t-plan", "eng", "t-deploy", "lobby")
        XCTAssertEqual(RoomSteps.next(list, open: "general", step: 1, pastThreads: true), "eng")
        XCTAssertNil(RoomSteps.next(list, open: "general", step: -1, pastThreads: true))
        // From a thread: on to the next room down, or up to the room it's under.
        XCTAssertEqual(RoomSteps.next(list, open: "t-cert", step: 1, pastThreads: true), "eng")
        XCTAssertEqual(RoomSteps.next(list, open: "t-cert", step: -1, pastThreads: true), "general")
        XCTAssertEqual(RoomSteps.next(list, open: "eng", step: 1, pastThreads: true), "lobby")
        XCTAssertNil(RoomSteps.next(rows("general", "t-cert"), open: "t-cert", step: 1, pastThreads: true))
    }
}
