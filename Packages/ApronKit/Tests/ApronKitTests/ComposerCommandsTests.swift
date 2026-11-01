import Foundation
import Synchronization
import XCTest
@testable import ApronKit

/// The composer's commands, as apron-web's `commands.ts`: which text is a command, the six the
/// client turns into requests, what each sends, and a failure giving the draft back.
@MainActor
final class ComposerCommandsTests: XCTestCase {
    private func action(_ text: String, command: Bool = true, rooms: Bool = true, members: Bool = true, mentions: [String: String] = [:]) -> ComposerAction {
        ComposerAction(text, command: command, rooms: rooms, members: members, mentions: mentions)
    }

    func testOneSlashIsACommandAndTwoPostAMessageWhereTheServerTakesCommands() {
        XCTAssertEqual(action("/kick @guest_2 spamming"), .command("/kick @guest_2 spamming"))
        XCTAssertEqual(action("//etc/hosts is odd"), .message("/etc/hosts is odd"))
        XCTAssertEqual(action("hello"), .message("hello"))
        XCTAssertEqual(action("/help", command: false), .message("/help"), "without capability command every text is a message")
        XCTAssertEqual(action("//x", command: false), .message("//x"))
    }

    func testTheClientHandlesTheSlashSpellingsOfExistingRequests() {
        XCTAssertEqual(action("/nick Ada L"), .nick("Ada L"))
        XCTAssertEqual(action("/join #ops"), .join("ops"))
        XCTAssertEqual(action("/leave"), .leave(nil))
        XCTAssertEqual(action("/leave ops"), .leave("ops"))
        XCTAssertEqual(action("/TOPIC Deploys *only* "), .topic("Deploys *only*"))
        XCTAssertEqual(action("/kick @guest_2"), .kick("guest_2"))
        XCTAssertEqual(action("/invite bob."), .invite("bob"))
        XCTAssertEqual(action("/nick"), .command("/nick"), "without an argument the server gets it")
        XCTAssertEqual(action("/join ops", rooms: false), .command("/join ops"))
        XCTAssertEqual(action("/kick @guest_2", members: false), .command("/kick @guest_2"))
        XCTAssertEqual(action("/kick"), .command("/kick"))
    }

    func testAUserArgumentReadsAsAppendixA3OrExactlyAsAPickedMention() {
        XCTAssertEqual(action("/kick @al-"), .kick("al"), "in text a trailing - is not part of the id")
        XCTAssertEqual(action("/kick @al-", mentions: ["al-": "al-"]), .kick("al-"))
        XCTAssertEqual(action("/kick @al", mentions: ["al": "al"]), .kick("al"))
        XCTAssertEqual(action("/kick @ada@example.com"), .kick("ada@example.com"))
        XCTAssertEqual(action("/invite carol:b.example."), .invite("carol:b.example"))
        XCTAssertEqual(action("/kick @Ada Okafor", mentions: ["ada": "Ada Okafor"]), .kick("ada"), "a picked name with a space")
        XCTAssertEqual(action("/kick @Ada Okafor"), .command("/kick @Ada Okafor"), "typed, it is a reason")
    }

    func testAFailedCommandsDraftComesBackOnlyToAnEmptySlot() {
        let key = DraftKey(server: UUID(), roomID: "general")
        let drafts = Drafts()
        let sent = ComposerDraft(field: DraftField(mode: .reply(LogID("7")!), text: "/topic Deploys"))
        XCTAssertTrue(drafts.restore(sent, at: key))
        XCTAssertEqual(drafts[key], sent)
        drafts[key] = ComposerDraft(field: DraftField(text: "typed since"))
        XCTAssertFalse(drafts.restore(sent, at: key))
        XCTAssertEqual(drafts[key].field.text, "typed since")
    }

    // MARK: On the wire

    private let record = ServerRecord(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000c")!, url: URL(string: "wss://chat.example/ws")!)
    private var session: ServerSession!
    private var socket: FakeTransport!

    override func tearDown() async throws {
        await session?.stop()
    }

    /// Signed in as Ada in `general` (with Bob) and its thread `t1`; `ops` is listed, not joined.
    private func signIn(capabilities: [String] = ["history", "rooms", "command"]) async throws {
        let tokens = InMemoryTokenStore()
        try tokens.setToken("t1", for: record.id)
        let counter = Mutex(0)
        let socket = FakeTransport()
        self.socket = socket
        session = ServerSession(record: record, tokens: tokens, environment: ServerSession.Environment(
            makeTransport: { _ in socket }, sleep: { _ in try await Task.sleep(for: .seconds(3600)) }, jitter: { 1 },
            makeRequestID: { counter.withLock { $0 += 1; return "c\($0)" } }))
        Task { await socket.deliver(["method": "server", "params": ["apron": 9, "auth": ["token"], "capabilities": .array(capabilities.map(JSONValue.string))]]) }
        session.start()
        await eventually("auth and room_list") { await socket.sentLog.count >= 2 }
        await socket.deliver(["id": "c1", "result": ["you": ["user_id": "ada", "name": "Ada"]]])
        await socket.deliver(["id": "c2", "result": [
            "joined": [
                ["room_id": "general", "log_id": "100", "title": "General", "description": "Old", "members": [["user_id": "ada"], ["user_id": "bob"]]],
                ["room_id": "t1", "log_id": "102", "title": "Deploys", "parent_room_id": "general", "members": [["user_id": "ada"]]],
            ],
            "not_joined": [["room_id": "ops", "log_id": "101", "title": "Operations"]],
        ]])
        await eventually("signed in") { self.session.status == .signedIn && self.session.joinedRoomIDs.count == 2 }
    }

    private func expectSent(_ index: Int, _ expected: String, file: StaticString = #filePath, line: UInt = #line) async {
        await eventually("frame \(index)") { await self.socket.sentLog.count > index }
        let frame = await socket.sentLog[index]
        XCTAssertEqual(frame, expected, file: file, line: line)
    }

    private func submit(_ text: String, in roomID: String = "general", mentions: [String: String] = [:]) -> Task<String?, Error> {
        Task { try await self.session.submit(ComposerDraft(field: DraftField(text: text, mentions: mentions)), in: roomID) }
    }

    func testEachLocalCommandSendsTheRequestItSpells() async throws {
        try await signIn()
        let nick = submit("/nick Ada L")
        await expectSent(2, #"{"id":"c3","method":"me","params":{"name":"Ada L"}}"#)
        await socket.deliver(["id": "c3", "result": ["you": ["user_id": "ada", "name": "Ada L"]]])
        let shown = try await nick.value
        XCTAssertNil(shown)
        XCTAssertEqual(session.you?.json["name"]?.stringValue, "Ada L")

        let topic = submit("/topic Deploys *only*")
        await expectSent(3, #"{"id":"c4","method":"room_set","params":{"description":"Deploys *only*","room_id":"general","title":"General"}}"#)
        await socket.deliver(["id": "c4", "result": ["room_id": "general"]])
        _ = try await topic.value

        let kick = submit("/kick @Bob", mentions: ["bob": "Bob"])
        await expectSent(4, #"{"id":"c5","method":"room_leave","params":{"room_id":"general","user_id":"bob"}}"#)
        await socket.deliver(["id": "c5", "result": [:]])
        _ = try await kick.value

        let invite = submit("/invite carol")
        await expectSent(5, #"{"id":"c6","method":"room_join","params":{"room_id":"general","user_id":"carol"}}"#)
        await socket.deliver(["id": "c6", "result": [:]])
        _ = try await invite.value

        let joined = submit("/join general")
        let opened = try await joined.value
        XCTAssertEqual(opened, "general", "a room you're in only opens")
        let join = submit("/join operations")
        await expectSent(6, #"{"id":"c7","method":"room_join","params":{"room_id":"ops"}}"#)
        await socket.deliver(["id": "c7", "result": [:]])
        let joinedOps = try await join.value
        XCTAssertEqual(joinedOps, "ops", "a listed room found by its title")

        let leave = submit("/leave", in: "t1")
        await expectSent(7, #"{"id":"c8","method":"room_leave","params":{"room_id":"t1"}}"#)
        await socket.deliver(["id": "c8", "result": [:]])
        let back = try await leave.value
        XCTAssertEqual(back, "general", "leaving a thread goes back to its room")
        let count = await socket.sentLog.count
        XCTAssertEqual(count, 8)
    }

    func testAnUnsupportedKickGoesToTheServerAsTyped() async throws {
        try await signIn()
        let kick = submit("/kick @bob")
        await expectSent(2, #"{"id":"c3","method":"room_leave","params":{"room_id":"general","user_id":"bob"}}"#)
        await socket.deliver(["id": "c3", "error": ["code": -32601, "message": "unsupported"]])
        await expectSent(3, #"{"id":"c4","method":"command","params":{"body":{"format":"plain","text":"/kick @bob"},"room_id":"general"}}"#)
        await socket.deliver(["id": "c4", "result": [:]])
        _ = try await kick.value
        XCTAssertEqual(session.action(for: DraftField(text: "/kick @bob"), withFiles: false), .command("/kick @bob"), "and the next one goes there first")
    }

    func testAFailedCommandLeavesANoticeAndGivesTheDraftBack() async throws {
        try await signIn()
        let draft = ComposerDraft(field: DraftField(mode: .reply(LogID("100")!), text: "/topic Deploys"))
        let topic = Task { try await self.session.submit(draft, in: "general") }
        await expectSent(2, #"{"id":"c3","method":"room_set","params":{"description":"Deploys","room_id":"general","title":"General"}}"#)
        await socket.deliver(["id": "c3", "error": ["code": -32001, "message": "Only moderators can change the topic"]])
        do {
            _ = try await topic.value
            XCTFail("the topic changed")
        } catch let failure as CommandFailure {
            XCTAssertEqual(failure, CommandFailure(reason: "Only moderators can change the topic", draft: draft))
        }
        XCTAssertEqual(session.notices.last, Notice(roomID: "general", from: UserObject(["user_id": "~private"])!,
                                                    body: ["text": "Only moderators can change the topic", "format": "plain"]))

        let help = submit("/frobnicate")
        await expectSent(3, #"{"id":"c4","method":"command","params":{"body":{"format":"plain","text":"/frobnicate"},"room_id":"general"}}"#)
        await socket.deliver(["id": "c4", "error": ["code": -32602, "message": "Unknown command: /frobnicate"]])
        do {
            _ = try await help.value
            XCTFail("ran")
        } catch let failure as CommandFailure {
            XCTAssertEqual(failure.draft.field.text, "/frobnicate", "a server's command gives its draft back too")
        }
        XCTAssertEqual(session.notices.last?.body?["text"]?.stringValue, "Unknown command: /frobnicate")
    }

    func testWithoutCommandsOrRoomsTheServerOrTheOutboxGetsTheText() async throws {
        try await signIn(capabilities: ["history", "command"])
        XCTAssertEqual(session.action(for: DraftField(text: "/join ops"), withFiles: false), .command("/join ops"))
        XCTAssertEqual(session.action(for: DraftField(text: "/nick Ada L"), withFiles: false), .nick("Ada L"))
        XCTAssertEqual(session.action(for: DraftField(text: "/nick Ada L"), withFiles: true), .command("/nick Ada L"), "files go with the server's own command")
        XCTAssertEqual(session.action(for: DraftField(text: "  //x  "), withFiles: false), .message("/x"))
    }

    func testWithoutCapabilityCommandASlashIsPostedAsWritten() async throws {
        try await signIn(capabilities: ["history", "rooms"])
        _ = try await submit("/nick Ada L").value
        await expectSent(2, #"{"id":"q-c3","method":"message","params":{"body":{"format":"plain","text":"/nick Ada L"},"room_id":"general"}}"#)
        await socket.deliver(["id": "q-c3", "result": ["message_id": "200"]])
        _ = try await submit("//x").value
        await expectSent(3, #"{"id":"q-c4","method":"message","params":{"body":{"format":"plain","text":"//x"},"room_id":"general"}}"#)
    }
}
