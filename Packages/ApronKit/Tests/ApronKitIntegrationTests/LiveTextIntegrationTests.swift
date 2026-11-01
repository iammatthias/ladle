@testable import ApronKit
import Foundation
import XCTest

/// Protocol v10 against the real Rust server: a message's terminal and append embeds waiting for
/// their writer without `url`, then read live over HTTP while a streaming `PUT` writes them,
/// their finished snapshots, `/embed-terminal`'s url refused once it ends, and read receipts in
/// a private room.
@MainActor
final class LiveTextIntegrationTests: XCTestCase {
    private var servers: [Aprond] = []
    private var sessions: [ServerSession] = []
    private var followers: [Task<Void, Never>] = []

    override func tearDown() async throws {
        for follower in followers { follower.cancel() }
        for session in sessions { await session.stop() }
        for server in servers { server.stop() }
    }

    private func connected(_ server: Aprond, record: ServerRecord? = nil, tokens: any TokenStore = InMemoryTokenStore(),
                           until state: ServerSession.Status = .signedOut) async throws -> ServerSession {
        let environment = ServerSession.Environment(makeTransport: { WebSocketTransport(url: $0.url, origin: $0.origin) }, readCursorInterval: .zero)
        let session = ServerSession(record: record ?? ServerRecord(url: server.url), tokens: tokens, environment: environment)
        sessions.append(session)
        session.start()
        try await waitFor("connected") { session.status == state }
        return session
    }

    private func account(_ server: Aprond, _ email: String, tokens: any TokenStore = InMemoryTokenStore()) async throws -> ServerSession {
        let session = try await connected(server, tokens: tokens)
        _ = try await session.signIn(.emailProposal(address: email))
        _ = try await session.signIn(.emailCode(try await server.emailCode(for: email)))
        return session
    }

    /// Posts a message with one live embed (§4.8.5) and gives the `write_url` its result lists for
    /// the sender. The message is broadcast at once, its embed waiting for its writer.
    private func postLive(_ embed: JSONValue, text: String, as session: ServerSession) async throws -> URL {
        try await session.open("general")
        let result = try await session.request("message", ["room_id": "general", "body": ["text": .string(text), "format": "markdown", "embeds": [embed]]])
        return try XCTUnwrap(result["embeds"]?.arrayValue?.first?["write_url"]?.stringValue.flatMap(URL.init(string:)))
    }

    /// Runs the command and reads the write URL out of its `~private` notice. aprond posts a
    /// command's message only when the write starts, with its url.
    private func writeURL(_ command: String, as session: ServerSession) async throws -> URL {
        try await session.open("general")
        _ = try await session.submit(ComposerDraft(field: DraftField(text: command)), in: "general")
        var found: URL?
        try await waitFor("the notice with the write URL") {
            found = session.notices.lazy.compactMap { notice -> URL? in
                let text = notice.body?["text"]?.stringValue ?? ""
                guard let match = text.firstMatch(of: /'(http[^']+\/write\/[^']+)'/) else { return nil }
                return URL(string: String(match.output.1))
            }.first
            return found != nil
        }
        return try XCTUnwrap(found)
    }

    private func follow(_ live: LiveText, in session: ServerSession) {
        followers.append(Task { await session.follow(live) })
    }

    /// The command's message, which comes waiting for its writer: its live embed has no `url`
    /// until the write starts (§4.8.5).
    private func waiting(_ kind: String, in session: ServerSession) async throws -> MessageSnapshot {
        var message: MessageSnapshot?
        try await waitFor("the message, waiting for its writer") {
            message = session.timeline("general").last { $0.embedList.contains { $0.kind == kind } }
            return message != nil
        }
        let embed = try XCTUnwrap(message?.embedList.first { $0.kind == kind })
        XCTAssertNil(embed.url, "no url before the write starts")
        XCTAssertTrue(embed.isWaitingForWriter)
        XCTAssertNil(session.liveText(of: embed))
        return try XCTUnwrap(message)
    }

    /// The snapshot that adds `url` once the write starts.
    private func started(_ waiting: MessageSnapshot, kind: String, in session: ServerSession) async throws -> MessageSnapshot {
        var message: MessageSnapshot?
        try await waitFor("the snapshot that adds url", timeout: .seconds(10)) {
            message = session.store.message(waiting.messageID)
            return message?.embedList.first { $0.kind == kind }?.url != nil
        }
        return try XCTUnwrap(message)
    }

    func testATerminalIsReadLiveThenShowsItsKeptOutput() async throws {
        let server = try await Aprond.start()
        servers.append(server)
        let ada = try await account(server, "ada@example.com")
        XCTAssertEqual(ada.server?.apron, 10)
        XCTAssertNil(ada.server?.versionWarning)
        XCTAssertTrue(ada.server?.has("embed:terminal") == true && ada.server?.has("embed:append") == true)
        let target = try await postLive(["kind": "terminal", "title": "make test"], text: "Running the tests:", as: ada)
        let pending = try await waiting("terminal", in: ada)
        let writer = StreamingPut(target)
        writer.send("\u{1B}[32mok\u{1B}[0m  first\r\n")
        let message: MessageSnapshot? = try await started(pending, kind: "terminal", in: ada)
        let embed = try XCTUnwrap(message?.embedList.first)
        XCTAssertEqual(embed.title, "make test")
        XCTAssertNil(embed.output)
        let live = try XCTUnwrap(ada.liveText(of: embed), "url is on the server's own origin: \(String(describing: embed.url))")
        follow(live, in: ada)
        try await waitFor("the first line", timeout: .seconds(10)) { live.screen.plainText == "ok  first" }
        XCTAssertEqual(live.screen.screen[0][0].style.foreground, .indexed(2))
        XCTAssertEqual(live.phase, .live)
        writer.send("progress  50%\rprogress 100%\r\n")
        try await waitFor("the redrawn line", timeout: .seconds(10)) { live.screen.plainText == "ok  first\nprogress 100%" }
        let status = await writer.finish()
        XCTAssertTrue((200..<300).contains(status), "the write ends with \(status)")
        try await waitFor("the finished snapshot", timeout: .seconds(10)) {
            ada.store.message(message!.messageID)?.embedList.first?.output != nil
        }
        let finished = try XCTUnwrap(ada.store.message(message!.messageID)?.embedList.first)
        XCTAssertNil(finished.url, "the finished embed carries output in place of url")
        XCTAssertEqual(TerminalScreen.showing(finished.output ?? "").plainText, "ok  first\nprogress 100%")
        XCTAssertNil(ada.liveText(of: finished))
        try await waitFor("GET ended") { live.phase == .ended }
    }

    func testAnAppendStreamsItsEditsAndEndsInTheBody() async throws {
        let server = try await Aprond.start()
        servers.append(server)
        let ada = try await account(server, "ada@example.com")
        let target = try await postLive(["kind": "append"], text: "**Plan:**\n\n", as: ada)
        let pending = try await waiting("append", in: ada)
        XCTAssertEqual(MessageRowModel(pending, in: ada).liveLine, "Waiting to stream…")
        let writer = StreamingPut(target)
        writer.send("_Thinking…_")
        let message: MessageSnapshot? = try await started(pending, kind: "append", in: ada)
        XCTAssertEqual(message?.plainText, "**Plan:**\n\n")
        let live = try XCTUnwrap(ada.appendedText(of: message!))
        follow(live, in: ada)
        try await waitFor("the placeholder", timeout: .seconds(10)) { live.text == "_Thinking…_" }
        writer.send("\u{0C}Roll back, then renew the cert. Every deploy faield")
        writer.send("\u{08}\u{08}\u{08}led.")
        try await waitFor("the edits", timeout: .seconds(10)) { live.text == "Roll back, then renew the cert. Every deploy failed." }
        let row = MessageRowModel(message!, in: ada)
        XCTAssertTrue(row.isWriting)
        XCTAssertEqual(String(MessageBlock.flattened(row.blocks).characters), "Plan:\nRoll back, then renew the cert. Every deploy failed.")
        _ = await writer.finish()
        try await waitFor("the snapshot without the embed", timeout: .seconds(10)) {
            ada.store.message(message!.messageID)?.embedList.isEmpty == true
        }
        XCTAssertEqual(ada.store.message(message!.messageID)?.plainText, "**Plan:**\n\nRoll back, then renew the cert. Every deploy failed.")
        XCTAssertNil(ada.appendedText(of: ada.store.message(message!.messageID)!))
    }

    /// `/live` against aprond: the composer's changes stream as edits a reader shows as they come,
    /// and Send saves the draft, mentions included, without the embed, which ends the text.
    func testSlashLiveStreamsTheComposerAndSendSavesItWithoutTheEmbed() async throws {
        let server = try await Aprond.start()
        servers.append(server)
        let ada = try await account(server, "ada@example.com")
        let bob = try await account(server, "bob@example.com")
        XCTAssertTrue(ada.canTypeLive)
        try await ada.open("general")
        try await bob.open("general")
        let bobID = try XCTUnwrap(bob.you?.userID)
        let bobName = bob.displayName(for: try XCTUnwrap(bob.you))
        let drafts = Drafts(), key = DraftKey(server: ada.record.id, roomID: "general")
        let live = LiveDraft(forget: { drafts[key] = ComposerDraft() }, restore: { drafts.restore(ComposerDraft(field: $0), at: key) })
        try await ada.submit(ComposerDraft(field: DraftField(text: "/live")), in: "general", live: live)
        XCTAssertEqual(ada.liveMessage?.roomID, "general")
        var message: MessageSnapshot?
        try await waitFor("bob sees the live message start", timeout: .seconds(10)) {
            message = bob.timeline("general").last { $0.embedList.first?.kind == "append" && $0.embedList.first?.url != nil }
            return message != nil
        }
        let reading = try XCTUnwrap(bob.appendedText(of: message!))
        follow(reading, in: bob)
        for typed in ["Roll", "Rolling bakc", "Rolling bak", "Rolling ba", "Rolling back the", "Rolling back now", "Rolling back now, @\(bobName)"] {
            ada.typedLive(DraftField(text: typed, mentions: typed.contains("@") ? [bobID: bobName] : [:]), in: "general")
            try await Task.sleep(for: .milliseconds(30))
        }
        try await waitFor("the edits, as typed", timeout: .seconds(10)) { reading.text == "Rolling back now, @\(bobName)" }
        XCTAssertTrue(MessageRowModel(message!, in: bob).isWriting)
        let final = "Rolling back now, @\(bobName). Done in five."
        try await ada.submit(ComposerDraft(field: DraftField(text: final, mentions: [bobID: bobName])), in: "general", live: live)
        XCTAssertNil(ada.liveMessage)
        try await waitFor("the saved message, without the embed", timeout: .seconds(10)) {
            bob.store.message(message!.messageID)?.embedList.isEmpty == true
        }
        let saved = try XCTUnwrap(bob.store.message(message!.messageID))
        XCTAssertEqual(saved.plainText, final)
        XCTAssertEqual(saved.mentionIDs, [bobID])
        XCTAssertNil(bob.appendedText(of: saved))
    }

    /// Send on a live message with nothing typed takes it back.
    func testSlashLiveSentEmptyDeletesTheMessage() async throws {
        let server = try await Aprond.start()
        servers.append(server)
        let ada = try await account(server, "ada@example.com")
        try await ada.open("general")
        let live = LiveDraft(forget: {}, restore: { _ in })
        try await ada.submit(ComposerDraft(field: DraftField(text: "/live")), in: "general", live: live)
        var message: MessageSnapshot?
        try await waitFor("the live message", timeout: .seconds(10)) {
            message = ada.timeline("general").last { $0.embedList.first?.kind == "append" && $0.embedList.first?.url != nil }
            return message != nil
        }
        try await ada.submit(ComposerDraft(), in: "general", live: live)
        try await waitFor("deleted", timeout: .seconds(10)) { ada.timeline("general").allSatisfy { $0.messageID != message!.messageID } }
        XCTAssertEqual(ada.store.message(message!.messageID)?.isTombstone, true)
    }

    func testAnEndedTextsURLIsRefusedForGood() async throws {
        let server = try await Aprond.start()
        servers.append(server)
        let ada = try await account(server, "ada@example.com")
        let target = try await writeURL("/embed-terminal", as: ada)
        let writer = StreamingPut(target)
        writer.send("done\r\n")
        var message: MessageSnapshot?
        try await waitFor("the command's message, posted with its url as the write starts") {
            message = ada.timeline("general").last { $0.embedList.contains { $0.kind == "terminal" } }
            return message != nil
        }
        let url = try XCTUnwrap(message?.embedList.first?.url)
        _ = await writer.finish()
        try await waitFor("finished", timeout: .seconds(10)) { ada.store.message(message!.messageID)?.embedList.first?.output != nil }
        var refusal: (any Error)?
        do { for try await _ in LiveTextFetch.live(url) {} } catch { refusal = error }
        XCTAssertEqual(refusal as? LiveTextRefused, LiveTextRefused(status: 404))
        XCTAssertEqual(ada.store.message(message!.messageID)?.embedList.first?.output, "done\r\n")
    }

    func testReadReceiptsReachTheOtherMemberOfAPrivateRoomUnlessTurnedOff() async throws {
        let server = try await Aprond.start()
        servers.append(server)
        let adaTokens = InMemoryTokenStore()
        let ada = try await account(server, "ada@example.com", tokens: adaTokens)
        let bob = try await account(server, "bob@example.com")
        XCTAssertTrue(ada.server?.showsReadReceipts == true)
        XCTAssertTrue(ada.offersReadReceipts)
        let bobID = try XCTUnwrap(bob.you?.userID)
        let room = try await ada.startPrivateRoom(with: [bobID]).roomID
        try await waitFor("bob is in the room") { bob.joinedRoomIDs.contains(room) }
        try await ada.open(room)
        try await bob.open(room)
        _ = try await ada.send("Got a minute?", in: room)
        try await waitFor("bob has it") { bob.timeline(room).count == 1 }
        let first = try XCTUnwrap(bob.timeline(room).first?.messageID)
        await bob.markRead(room, through: first)
        try await waitFor("ada sees bob's cursor") { ada.readers[room]?[bobID] == first }
        XCTAssertEqual(ada.receipts(in: room, shown: ada.timeline(room)).mapValues { $0.map(\.user.userID) }, [first: [bobID]])

        bob.receiptSettings.set(false)
        _ = try await ada.send("Still there?", in: room)
        try await waitFor("bob has the second") { bob.timeline(room).count == 2 }
        let second = try XCTUnwrap(bob.timeline(room).last?.messageID)
        await bob.markRead(room, through: second)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(ada.readers[room]?[bobID], first, "off, bob's cursor stays on his device")
        bob.receiptSettings.set(true)
        await bob.readReceiptsTurnedOn()
        try await waitFor("back on, it goes") { ada.readers[room]?[bobID] == second }

        let later = try await connected(server, record: ada.record, tokens: adaTokens, until: .signedIn)
        try await waitFor("a new session hears the cursor after its joined listing") { later.readers[room]?[bobID] == second }
    }
}

/// A streaming `PUT` to a write URL (§4.8.3) through the app's own writer (`LiveTextWriter`), its
/// body written a piece at a time, as `curl -T -` sends a pipe.
@MainActor
private final class StreamingPut {
    private let body: AsyncStream<Data>.Continuation
    private let task: Task<LiveTextWriteResponse, any Error>

    init(_ url: URL) {
        let (stream, body) = AsyncStream.makeStream(of: Data.self)
        self.body = body
        task = Task { try await LiveTextWriter.live(url, stream) }
    }

    func send(_ text: String) {
        body.yield(Data(text.utf8))
    }

    func finish() async -> Int {
        body.finish()
        return (try? await task.value.status) ?? -1
    }
}
