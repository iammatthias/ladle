import Foundation
import Synchronization
import XCTest
@testable import ApronKit

final class MessageSelectionTests: XCTestCase {
    private let order = (1 ... 6).map { LogID(String($0))! }
    private func id(_ value: Int) -> LogID { LogID(String(value))! }

    func testPicksAndUnpicksAndEndsOnceNothingIsLeft() {
        var selection = MessageSelection(roomID: "general", first: id(2))
        XCTAssertEqual(selection.countWords, "1 message selected")
        XCTAssertTrue(selection.toggle(id(4), order: order))
        XCTAssertEqual(selection.ids, [id(2), id(4)])
        XCTAssertEqual(selection.countWords, "2 messages selected")
        XCTAssertTrue(selection.toggle(id(2), order: order))
        XCTAssertFalse(selection.toggle(id(4), order: order), "nothing left: select mode ends")
    }

    func testARangeFillsFromTheLastPickedAlongTheTimeline() {
        var selection = MessageSelection(roomID: "general", first: id(5))
        _ = selection.toggle(id(2), order: order, range: true)
        XCTAssertEqual(selection.ids, [id(2), id(3), id(4), id(5)])
        _ = selection.toggle(id(9), order: order, range: true)
        XCTAssertEqual(selection.ids, [id(2), id(9)], "a message the timeline doesn't hold takes the two ends alone")
    }

    func testSelectBetweenFillsTheGapAndTheEarliestSuggestsTheTitle() {
        var selection = MessageSelection(roomID: "general", first: id(5))
        _ = selection.toggle(id(2), order: order)
        XCTAssertEqual(selection.earliest(order: order), id(2))
        selection.fillBetween(order: order)
        XCTAssertEqual(selection.ids, [id(2), id(3), id(4), id(5)])
    }

    func testARefusalKeepsWhatStayedAndSaysHowMany() {
        var selection = MessageSelection(roomID: "general", first: id(1))
        _ = selection.toggle(id(2), order: order)
        selection.keep([id(2)], of: 2)
        XCTAssertEqual(selection.ids, [id(2)])
        XCTAssertEqual(selection.denied?.words, "1 of 2 couldn’t be moved")
        _ = selection.toggle(id(3), order: order)
        XCTAssertNil(selection.denied, "picking again puts the note away")
    }
}

/// Select mode's moves over the wire, as apron-web's `selection.svelte.test.ts`.
@MainActor
final class SelectionSessionTests: XCTestCase {
    static let greeting: JSONValue = ["method": "server", "params": ["apron": 9, "auth": ["guest"], "capabilities": ["history", "rooms", "edit", "reactions"]]]
    let transports = Transports()
    var session: ServerSession!
    var socket: FakeTransport!

    override func setUp() async throws {
        let counter = Mutex(0)
        let transports = transports
        let environment = ServerSession.Environment(
            makeTransport: { _ in transports.next() }, sleep: { try await Task.sleep(for: $0) }, jitter: { 1 },
            makeRequestID: { counter.withLock { $0 += 1; return "c\($0)" } }, makeState: { "s" }, agent: "ladle-ios/test", pageSize: 3)
        socket = FakeTransport()
        transports.queued.withLock { $0 = [socket] }
        await socket.deliver(Self.greeting)
        session = ServerSession(record: ServerRecord(url: URL(string: "wss://chat.example/ws")!), tokens: InMemoryTokenStore(), environment: environment)
        session.start()
        await eventually("signed out") { self.session.status == .signedOut }
        let signIn = Task { try await self.session.signIn(.guest(name: nil)) }
        _ = await frame(1)
        await socket.deliver(["id": "c1", "result": ["you": ["user_id": "ada", "name": "Ada"]]])
        await socket.deliver(["id": "c2", "result": ["joined": [
            ["room_id": "general", "log_id": "100", "title": "General", "latest_log_id": "100", "members": [["user_id": "ada"], ["user_id": "bob"], ["user_id": "cy"]]],
            ["room_id": "t1", "log_id": "101", "title": "Deploy", "parent_room_id": "general", "latest_log_id": "101", "members": [["user_id": "ada"], ["user_id": "cy"]]],
        ]]])
        _ = try await signIn.value
        for (id, from) in [(201, "bob"), (202, "ada"), (203, "cy"), (204, "bob")] {
            await socket.deliver(["method": "message", "params": ["message_id": .string(String(id)), "log_id": .string(String(id)), "room_id": "general",
                                                                  "from": ["user_id": .string(from)], "body": ["text": .string("#\(id)")]]])
        }
        await eventually("messages") { self.session.store.messages(in: "general").count == 4 }
    }

    override func tearDown() async throws {
        await session.stop()
    }

    private func frame(_ index: Int) async -> String {
        await eventually("frame \(index)") { await self.socket.sentLog.count > index }
        return await socket.sentLog[index]
    }

    private func selection(_ ids: [Int]) -> MessageSelection {
        var selection = MessageSelection(roomID: "general", first: LogID(String(ids[0]))!)
        for id in ids.dropFirst() { _ = selection.toggle(LogID(String(id))!, order: []) }
        return selection
    }

    private func move(_ ids: [Int], to room: String, answers: [JSONValue?]) async -> (SelectionMove, MessageSelection, [String]) {
        var picked = selection(ids)
        let start = await socket.sentLog.count
        let mover = Task { [picked] in
            var picked = picked
            let result = await self.session.move(&picked, to: room)
            return (result, picked)
        }
        for (offset, answer) in answers.enumerated() {
            let index = start + offset
            _ = await frame(index)
            let reply: JSONValue = answer.map { ["id": .string("c\(index + 1)"), "error": $0] } ?? ["id": .string("c\(index + 1)"), "result": [:]]
            await socket.deliver(reply)
        }
        let (result, after) = await mover.value
        picked = after
        let sent = await Array(socket.sentLog.dropFirst(start))
        return (result, picked, sent)
    }

    func testTriesSomeoneElsesMessageFirstThenMovesTheRestAndAddsTheirAuthorsOnce() async {
        let (result, _, sent) = await move([202, 201, 203, 204], to: "t1", answers: [nil, nil, nil, nil, nil])
        XCTAssertEqual(sent, [
            ##"{"id":"c3","method":"message","params":{"body":{"text":"#201"},"message_id":"201","room_id":"t1"}}"##,
            ##"{"id":"c4","method":"message","params":{"body":{"text":"#202"},"message_id":"202","room_id":"t1"}}"##,
            ##"{"id":"c5","method":"message","params":{"body":{"text":"#203"},"message_id":"203","room_id":"t1"}}"##,
            ##"{"id":"c6","method":"message","params":{"body":{"text":"#204"},"message_id":"204","room_id":"t1"}}"##,
            #"{"id":"c7","method":"room_join","params":{"room_id":"t1","user_id":"bob"}}"#,
        ], "Bob once; not you, and not Cy, who is in the thread")
        XCTAssertTrue(result.moved)
        XCTAssertNil(result.unadded)
    }

    func testMovesNoneWhenTheServerRefusesSomeoneElsesMessage() async {
        let (result, picked, sent) = await move([202, 201], to: "t1", answers: [["code": -32001, "message": "You may only move your own messages"]])
        XCTAssertEqual(sent.count, 1, "nothing else is sent")
        XCTAssertFalse(result.moved)
        XCTAssertEqual(result.problem, "No messages were moved: You may only move your own messages")
        XCTAssertEqual(picked.ids.map(\.text), ["202", "201"], "the selection stays as it was")
    }

    func testKeepsThoseRefusedAfterTheProbeAndStillAddsTheAuthorsOfThoseMoved() async {
        let (result, picked, sent) = await move([201, 202, 204], to: "t1", answers: [nil, ["code": -32029, "message": "Too fast"], nil, ["code": -32001, "message": "Guests can't be added"]])
        XCTAssertEqual(sent.count, 4)
        XCTAssertFalse(result.moved)
        XCTAssertEqual(result.problem, "Too fast")
        XCTAssertEqual(picked.ids.map(\.text), ["202"])
        XCTAssertEqual(picked.denied?.words, "1 of 3 couldn’t be moved")
        XCTAssertEqual(result.unadded, "Moved, but the author couldn’t be added to the thread: Guests can't be added")
    }

    func testAddsNoOneMovingBackToTheRoom() async {
        let (result, _, sent) = await move([202], to: "general", answers: [nil])
        XCTAssertEqual(sent, [##"{"id":"c3","method":"message","params":{"body":{"text":"#202"},"message_id":"202","room_id":"general"}}"##])
        XCTAssertTrue(result.moved)
    }

    func testTheLogQuotesThePickedMessagesInTimelineOrderAndSaysWhatIsLeftOut() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // Ids this small read as milliseconds into 1970, as apron-web's `idMillis` reads them.
        XCTAssertEqual(session.markdownLog(of: [LogID("204")!, LogID("201")!], in: "general", now: Date(timeIntervalSince1970: 0), calendar: calendar), [
            "> **bob** · Thursday, Jan 1, 1970 at 12:00\u{202F}AM", ">", "> #201", "",
            "_(2 messages omitted)_", "",
            "> **bob** · 12:00\u{202F}AM", ">", "> #204",
        ].joined(separator: "\n"))
    }
}
