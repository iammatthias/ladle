import Foundation
import Synchronization
import XCTest
@testable import ApronKit

/// A write a test reads: what readers would show, whether the body ended, and the server's
/// answer, given when the test says.
final class FakeLiveWrite: Sendable {
    private struct State {
        var shown = ""
        var closed = false
        var urls: [URL] = []
        var answer: CheckedContinuation<LiveTextWriteResponse, any Error>?
    }

    private let state = Mutex(State())

    var shown: String { state.withLock { $0.shown } }
    var closed: Bool { state.withLock { $0.closed } }
    var urls: [URL] { state.withLock { $0.urls } }

    var write: LiveTextWrite {
        { url, body in
            self.state.withLock { $0.urls.append(url) }
            Task {
                var decoder = LiveTextDecoder()
                for await chunk in body {
                    let text = decoder.decode(chunk)
                    self.state.withLock { LiveTextEdit.apply(text, to: &$0.shown) }
                }
                self.state.withLock { $0.closed = true }
            }
            return try await withCheckedThrowingContinuation { continuation in self.state.withLock { $0.answer = continuation } }
        }
    }

    func respond(_ status: Int, _ text: String) async {
        await waitForWrite()
        state.withLock { $0.answer?.resume(returning: LiveTextWriteResponse(status: status, body: Data(text.utf8))); $0.answer = nil }
    }

    func fail(_ error: any Error) async {
        await waitForWrite()
        state.withLock { $0.answer?.resume(throwing: error); $0.answer = nil }
    }

    private func waitForWrite() async {
        while state.withLock({ $0.answer == nil }) { try? await Task.sleep(for: .milliseconds(1)) }
    }
}

/// Typing live (`/live`, §4.8.5), as apron-web's `live-typing.ts` and `live-composer.svelte.ts`
/// (#191): the edit each change goes out as, the write following the composer, how it ends, and
/// on the wire the post, the save that finishes it and what a failure gives back. The cases are
/// apron-web's `live-typing.test.ts` and `commands.test.ts` with their literal values.
@MainActor
final class LiveTypingTests: XCTestCase {
    // MARK: The edit

    func testTypingAtTheEndGoesAsItIsAndNoChangeAsNothing() {
        XCTAssertEqual(LiveEdit.between("", "hi"), "hi")
        XCTAssertEqual(LiveEdit.between("hi", "hi there"), " there")
        XCTAssertEqual(LiveEdit.between("same", "same"), "")
    }

    func testOneCharacterDeletedFromTheEndBackspacesByCodePoint() {
        XCTAssertEqual(LiveEdit.between("hello", "hell"), "\u{08}")
        XCTAssertEqual(LiveEdit.between("a😀", "a"), "\u{08}")
        XCTAssertEqual(LiveEdit.between("ok 👍🏽", "ok "), "\u{08}\u{08}", "an emoji with its skin tone is one character of two code points")
        XCTAssertEqual(LiveEdit.between("ok 👍🏽", "ok 👍"), "\u{08}", "the skin tone alone, as apron-web compares by code unit")
    }

    func testReplacedTextResetsToTheWholeText() {
        XCTAssertEqual(LiveEdit.between("Hello there, world", "Hello th"), "\u{0C}Hello th", "the second half selected and deleted")
        XCTAssertEqual(LiveEdit.between("Hello th", "Hello thx"), "x")
        XCTAssertEqual(LiveEdit.between("Hello there, world", "ere, world"), "\u{0C}ere, world", "the first half selected and deleted")
        XCTAssertEqual(LiveEdit.between("Hello wrold", "Hello world"), "\u{0C}Hello world", "a selection typed over")
        XCTAssertEqual(LiveEdit.between("Helo world", "Hello world"), "\u{0C}Hello world", "an edit before the end")
        XCTAssertEqual(LiveEdit.between("a😀", "a😃"), "\u{0C}a😃")
        XCTAssertEqual(LiveEdit.between("abc", ""), "\u{0C}")
    }

    func testCanonicallyEquivalentTextsAreStillDifferentEdits() {
        XCTAssertEqual(LiveEdit.between("caf\u{E9}", "cafe\u{301}"), "\u{0C}cafe\u{301}", "Swift's == calls them equal; readers don't")
        XCTAssertEqual(LiveEdit.between("cafe\u{301}", "cafe"), "\u{08}")
    }

    func testReadersGetTheNewTextWhateverTheChange() {
        let texts = ["", "h", "he", "hello", "hell", "help", "help 😀", "help 😃!", "x", "xy\nz", "", "日本語", "日本", "日本 👍🏽", "日本 "]
        var shown = "", sent = ""
        for next in texts {
            LiveTextEdit.apply(LiveEdit.between(sent, next), to: &shown)
            sent = next
            XCTAssertEqual(shown, next)
        }
    }

    func testBackspaceAndFormFeedAreLeftOutOfWhatIsSent() {
        XCTAssertEqual(LiveEdit.text("a\u{08}b\u{0C}c"), "abc")
    }

    func testTheServersReasonIsItsFirstLine() {
        XCTAssertEqual(LiveTextWriteResponse(status: 413, body: Data("This live text is limited to 64 KB; it ended\nmore\n".utf8)).reason,
                       "This live text is limited to 64 KB; it ended")
        XCTAssertEqual(LiveTextWriteResponse(status: 200).reason, "")
    }

    // MARK: The write

    private func transport(_ write: FakeLiveWrite, start: (@MainActor () async throws -> (messageID: LogID, writeURL: URL))? = nil) -> LiveTyping.Transport {
        LiveTyping.Transport(start: start ?? { (LogID("1")!, URL(string: "https://chat.example/w/1")!) }, write: write.write)
    }

    func testTheWriteFollowsTheComposerAndReadersShowIt() async {
        let write = FakeLiveWrite()
        var ends: [LiveTypingEnd] = []
        let typing = LiveTyping(transport: transport(write)) { ends.append($0) }
        typing.update("hel")
        await typing.started()
        typing.update("hello")
        typing.update("help")
        typing.update("help me")
        await eventually("the edits") { write.shown == "help me" }
        XCTAssertEqual(typing.text, "help me")
        let finished = await typing.finish()
        XCTAssertEqual(finished, LogID("1"))
        XCTAssertFalse(typing.isActive)
        typing.update("ignored")
        typing.close()
        await eventually("the body ends") { write.closed }
        XCTAssertEqual(write.shown, "help me")
        XCTAssertEqual(ends, [])
    }

    func testWhatWasTypedBeforeTheMessageWasPostedIsWritten() async {
        let write = FakeLiveWrite()
        let typing = LiveTyping(transport: transport(write)) { _ in }
        typing.update("early")
        await typing.started()
        await eventually("the early text") { write.shown == "early" }
    }

    func testAWriteThatCouldNotBeMadeFails() async {
        let write = FakeLiveWrite()
        var ends: [LiveTypingEnd] = []
        let typing = LiveTyping(transport: transport(write)) { ends.append($0) }
        await typing.started()
        await write.fail(URLError(.networkConnectionLost))
        await eventually("ended") { !ends.isEmpty }
        XCTAssertEqual(ends, [LiveTypingEnd(.failed, messageID: LogID("1"), reason: "this connection can’t stream live text")])
        XCTAssertFalse(typing.isActive)
        let finished = await typing.finish()
        XCTAssertNil(finished)
    }

    func testATextTheServerEndedSaysItsReasonWhateverItsStatus() async {
        for (status, said) in [(413, "This live text is limited to 64 KB; it ended\n"), (200, "The text reached its 2m limit; what arrived is posted.\n")] {
            let write = FakeLiveWrite()
            var ends: [LiveTypingEnd] = []
            let typing = LiveTyping(transport: transport(write)) { ends.append($0) }
            await typing.started()
            await write.respond(status, said)
            await eventually("ended") { !ends.isEmpty }
            XCTAssertEqual(ends, [LiveTypingEnd(.ended, messageID: LogID("1"), reason: said.trimmingCharacters(in: .newlines))])
        }
    }

    func testAConnectionDroppedAfterTextWentOutEndsItAndTheServerKeepsWhatArrived() async {
        let write = FakeLiveWrite()
        var ends: [LiveTypingEnd] = []
        let typing = LiveTyping(transport: transport(write)) { ends.append($0) }
        await typing.started()
        typing.update("partial")
        await write.fail(URLError(.networkConnectionLost))
        await eventually("ended") { !ends.isEmpty }
        XCTAssertEqual(ends, [LiveTypingEnd(.ended, messageID: LogID("1"), reason: "the connection to the server dropped")])
    }

    func testAMessageThatWasNotPostedFails() async {
        var ends: [LiveTypingEnd] = []
        let typing = LiveTyping(transport: transport(FakeLiveWrite()) { throw RPCError(code: -32001, message: "Not allowed") }) { ends.append($0) }
        await typing.started()
        XCTAssertEqual(ends, [LiveTypingEnd(.failed, reason: "Not allowed")])
    }

    func testTheWriteEndingAfterItWasFinishedSaysNothing() async {
        let write = FakeLiveWrite()
        var ends: [LiveTypingEnd] = []
        let typing = LiveTyping(transport: transport(write)) { ends.append($0) }
        await typing.started()
        _ = await typing.finish()
        await write.respond(410, "gone")
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(ends, [])
    }

    // MARK: The command

    func testSlashLiveIsLadlesOwnWithEmbedAppendWithOrWithoutCommand() {
        XCTAssertEqual(ComposerAction("/live", command: true, rooms: true, append: true), .live)
        XCTAssertEqual(ComposerAction("/LIVE ", command: false, rooms: false, append: true), .live)
    }

    func testSlashLiveGoesAsTypedWithoutEmbedAppendOrWithAnArgument() {
        XCTAssertEqual(ComposerAction("/live", command: true, rooms: true), .command("/live"))
        XCTAssertEqual(ComposerAction("/live", command: false, rooms: false), .message("/live"))
        XCTAssertEqual(ComposerAction("/live now", command: true, rooms: true, append: true), .command("/live now"))
    }

    // MARK: On the wire

    private let record = ServerRecord(id: UUID(uuidString: "00000000-0000-0000-0000-00000000001f")!, url: URL(string: "wss://chat.example/ws")!)
    private var session: ServerSession!
    private var socket: FakeTransport!
    private var write: FakeLiveWrite!
    private let key = DraftKey(server: UUID(uuidString: "00000000-0000-0000-0000-00000000001f")!, roomID: "general")
    private var drafts: Drafts!

    override func tearDown() async throws {
        await session?.stop()
    }

    /// Signed in as Ada in `general`, with Bob, on a server with `embed:append`.
    private func signIn(capabilities: [String] = ["history", "rooms", "command", "edit", "activity", "embed:append"]) async throws {
        let tokens = InMemoryTokenStore()
        try tokens.setToken("t1", for: record.id)
        let counter = Mutex(0)
        let socket = FakeTransport(), write = FakeLiveWrite()
        self.socket = socket
        self.write = write
        drafts = Drafts()
        session = ServerSession(record: record, tokens: tokens, environment: ServerSession.Environment(
            makeTransport: { _ in socket }, sleep: { _ in try await Task.sleep(for: .seconds(3600)) }, jitter: { 1 },
            makeRequestID: { counter.withLock { $0 += 1; return "c\($0)" } }, writeLiveText: write.write))
        Task { await socket.deliver(["method": "server", "params": ["apron": 10, "auth": ["token"], "capabilities": .array(capabilities.map(JSONValue.string))]]) }
        session.start()
        await eventually("auth and room_list") { await socket.sentLog.count >= 2 }
        await socket.deliver(["id": "c1", "result": ["you": ["user_id": "ada", "name": "Ada"]]])
        await socket.deliver(["id": "c2", "result": ["joined": [
            ["room_id": "general", "log_id": "100", "title": "General", "members": [["user_id": "ada"], ["user_id": "bob", "name": "Bob"]]],
        ]]])
        await eventually("signed in") { self.session.status == .signedIn && self.session.joinedRoomIDs.count == 1 }
    }

    private var liveDraft: LiveDraft {
        let drafts = drafts!, key = key
        return LiveDraft(forget: { drafts[key] = ComposerDraft() }, restore: { drafts.restore(ComposerDraft(field: $0), at: key) })
    }

    private func expectSent(_ index: Int, _ expected: String, file: StaticString = #filePath, line: UInt = #line) async {
        await eventually("frame \(index)") { await self.socket.sentLog.count > index }
        let frame = await socket.sentLog[index]
        XCTAssertEqual(frame, expected, file: file, line: line)
    }

    /// Sends the draft as `TimelineView` does: the composer empties, then it is submitted.
    private func send(_ field: DraftField) async throws {
        drafts[key] = ComposerDraft()
        try await session.submit(ComposerDraft(field: field), in: "general", live: liveDraft)
    }

    /// `/live` replying to message 90, its message posted, and its write started.
    private func startLive() async throws {
        try await send(DraftField(mode: .reply(LogID("90")!), text: "/live"))
        XCTAssertEqual(session.liveMessage?.roomID, "general")
        await expectSent(2, #"{"id":"c3","method":"message","params":{"body":{"embeds":[{"kind":"append"}],"format":"markdown","text":""},"reply_to":{"message_id":"90"},"room_id":"general"}}"#)
        await socket.deliver(["id": "c3", "result": ["message_id": "120", "embeds": [["kind": "append", "write_url": "https://chat.example/write/k1"]]]])
        await eventually("the write started") { self.write.urls == [URL(string: "https://chat.example/write/k1")!] }
    }

    private func type(_ text: String, mentions: [String: String] = [:], mode: DraftField.Mode = .new) {
        let field = DraftField(mode: mode, text: text, mentions: mentions)
        drafts[key] = ComposerDraft(field: field)
        session.typedLive(field, in: "general")
    }

    func testSendSavesTheDraftWithItsMentionsAndReplyWithoutTheEmbedThenEndsTheWrite() async throws {
        try await signIn()
        try await startLive()
        type("Rolling bakc")
        type("Rolling back")
        type("Rolling back, @Bob", mentions: ["bob": "Bob"])
        await eventually("the edits") { self.write.shown == "Rolling back, @Bob" }
        session.composerChanged(in: "general")
        try await send(DraftField(text: "Rolling back, @Bob?", mentions: ["bob": "Bob"]))
        XCTAssertNil(session.liveMessage)
        await expectSent(3, #"{"id":"c4","method":"message","params":{"body":{"format":"markdown","mentions":["bob"],"text":"Rolling back, @Bob?"},"message_id":"120","reply_to":{"message_id":"90"},"room_id":"general"}}"#)
        XCTAssertFalse(write.closed, "the write ends once the save is made")
        await socket.deliver(["id": "c4", "result": ["message_id": "120"]])
        await eventually("the write ended") { self.write.closed }
        XCTAssertEqual(write.shown, "Rolling back, @Bob?")
        let count = await socket.sentLog.count
        XCTAssertEqual(count, 4, "no typing indicator went out while typing live")
    }

    func testAReplyPickedWhileLiveIsTheOneSaved() async throws {
        try await signIn()
        try await startLive()
        type("Yes", mode: .reply(LogID("95")!))
        try await send(DraftField(mode: .reply(LogID("95")!), text: "Yes"))
        await expectSent(3, #"{"id":"c4","method":"message","params":{"body":{"format":"markdown","text":"Yes"},"message_id":"120","reply_to":{"message_id":"95"},"room_id":"general"}}"#)
    }

    func testSendWithNothingTypedDeletesTheMessage() async throws {
        try await signIn()
        try await startLive()
        type("  ")
        try await send(DraftField(text: "  "))
        await expectSent(3, #"{"id":"c4","method":"message","params":{"deleted":true,"message_id":"120","room_id":"general"}}"#)
    }

    func testLeavingTheRoomFinishesItAsSendWouldFromTheDraftAsLastSeen() async throws {
        try await signIn()
        try await startLive()
        type("Back in five")
        session.show("general", false)
        await expectSent(3, #"{"id":"c4","method":"message","params":{"body":{"format":"markdown","text":"Back in five"},"message_id":"120","reply_to":{"message_id":"90"},"room_id":"general"}}"#)
        XCTAssertTrue(drafts[key].isEmpty, "the composer empties")
    }

    func testGoingToTheBackgroundFinishesItBeforeTheSessionStops() async throws {
        try await signIn()
        try await startLive()
        type("Back in five")
        let suspending = Task { await self.session.suspend(deadline: .milliseconds(10)) }
        await expectSent(3, #"{"id":"c4","method":"message","params":{"body":{"format":"markdown","text":"Back in five"},"message_id":"120","reply_to":{"message_id":"90"},"room_id":"general"}}"#)
        await socket.deliver(["id": "c4", "result": ["message_id": "120"]])
        await suspending.value
        XCTAssertTrue(write.closed)
    }

    func testAWriteThatCantBeMadeDeletesTheMessageAndGivesTheDraftBack() async throws {
        try await signIn()
        try await startLive()
        await write.fail(URLError(.cannotConnectToHost))
        await expectSent(3, #"{"id":"c4","method":"message","params":{"deleted":true,"message_id":"120","room_id":"general"}}"#)
        XCTAssertNil(session.liveMessage)
        XCTAssertEqual(drafts[key].field, DraftField(mode: .reply(LogID("90")!)), "the reply it was posted with comes back")
        XCTAssertEqual(session.notices(in: "general").last?.body?["text"]?.stringValue, "Live typing stopped: this connection can’t stream live text")
    }

    func testAConnectionDroppedOnceTextWentOutKeepsTheMessageAndFinishesIt() async throws {
        try await signIn()
        try await startLive()
        type("half a thought")
        await eventually("written") { self.write.shown == "half a thought" }
        await write.fail(URLError(.networkConnectionLost))
        await expectSent(3, #"{"id":"c4","method":"message","params":{"body":{"format":"markdown","text":"half a thought"},"message_id":"120","reply_to":{"message_id":"90"},"room_id":"general"}}"#)
        XCTAssertEqual(session.notices(in: "general").last?.body?["text"]?.stringValue, "The live message ended early: the connection to the server dropped")
    }

    func testAPostTheServerRefusesGivesTheDraftBack() async throws {
        try await signIn()
        try await send(DraftField(text: "/live"))
        type("first words")
        await expectSent(2, #"{"id":"c3","method":"message","params":{"body":{"embeds":[{"kind":"append"}],"format":"markdown","text":""},"room_id":"general"}}"#)
        drafts[key] = ComposerDraft()
        await socket.deliver(["id": "c3", "error": ["code": -32001, "message": "Live text is off here"]])
        await eventually("given back") { !self.drafts[self.key].isEmpty }
        XCTAssertEqual(drafts[key].field.text, "first words")
        XCTAssertEqual(session.notices(in: "general").last?.body?["text"]?.stringValue, "Live typing stopped: Live text is off here")
    }

    func testATextTheServerEndsIsFinishedFromTheDraftWithItsReason() async throws {
        try await signIn()
        try await startLive()
        type("A long report")
        await eventually("written") { self.write.shown == "A long report" }
        await write.respond(413, "This live text is limited to 64 KB; it ended\n")
        await expectSent(3, #"{"id":"c4","method":"message","params":{"body":{"format":"markdown","text":"A long report"},"message_id":"120","reply_to":{"message_id":"90"},"room_id":"general"}}"#)
        XCTAssertNil(session.liveMessage)
        XCTAssertTrue(drafts[key].isEmpty)
        XCTAssertEqual(session.notices(in: "general").last?.body?["text"]?.stringValue, "The live message ended early: This live text is limited to 64 KB; it ended")
    }

    func testSlashLiveWithFilesStagedAsksToSendOrRemoveThemFirst() async throws {
        try await signIn()
        let file = StagedFile(name: "plan.pdf", phase: .preparing)
        do {
            try await session.submit(ComposerDraft(field: DraftField(text: "/live"), files: [file]), in: "general", live: liveDraft)
            XCTFail("refused")
        } catch let failure as CommandFailure {
            XCTAssertEqual(failure.reason, "Send or remove the attached files before typing live.")
        }
        XCTAssertNil(session.liveMessage)
    }

    func testStopTakesTheMessageBackAndKeepsTheDraft() async throws {
        try await signIn()
        try await startLive()
        type("never mind")
        session.stopLiveTyping()
        await expectSent(3, #"{"id":"c4","method":"message","params":{"deleted":true,"message_id":"120","room_id":"general"}}"#)
        XCTAssertEqual(drafts[key].field.text, "never mind")
        await eventually("the write ended") { self.write.closed }
    }

    func testAWriteThatEndsAsStopTakesItBackStillDeletesIt() async throws {
        try await signIn()
        try await startLive()
        type("never mind")
        session.stopLiveTyping()
        await write.respond(413, "limit\n")
        await expectSent(3, #"{"id":"c4","method":"message","params":{"deleted":true,"message_id":"120","room_id":"general"}}"#)
        await socket.deliver(["id": "c4", "result": [:]])
        try? await Task.sleep(for: .milliseconds(20))
        let count = await socket.sentLog.count
        XCTAssertEqual(count, 4, "no save follows")
        XCTAssertEqual(drafts[key].field.text, "never mind")
    }
}
