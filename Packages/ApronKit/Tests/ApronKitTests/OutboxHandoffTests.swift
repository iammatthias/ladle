@testable import ApronKit
import Foundation
import XCTest

/// The handoff from a queued message's row to the message the server logged, in both orders the
/// echo and the result arrive, and an edit shown before its echo.
@MainActor
final class OutboxHandoffTests: ScriptedSessionCase {
    private var socket: FakeTransport!

    override func setUp() async throws {
        try await super.setUp()
        socket = queueTransport(capabilities: ["history", "edit", "rooms", "reactions", "command"])
        session.start()
        try await signIn(socket)
        session.show("general", true)
    }

    /// Each message row of general as "<item id> <text>", with its outbox state: sending, not
    /// sent, sent (the server logged it, its snapshot still to come), or logged (the row shows the
    /// stored message under the queued one's identity).
    private func rows() -> [String] {
        session.timelineItems("general", lineBefore: nil).compactMap { item in
            guard case .message(let message, _, let pending) = item else { return nil }
            let state: String
            switch pending?.state {
            case .sending?: state = " (sending)"
            case .failed(let reason)?: state = " (not sent: \(reason))"
            case .sent(let id)?: state = id == message.messageID ? " (logged \(id.text))" : " (sent, awaiting \(id.text))"
            case nil: state = ""
            }
            return "\(item.id) \(message.plainText)\(state)"
        }
    }

    private func echo(_ id: String, _ text: String, from userID: String = "ada", embeds: JSONValue? = nil) -> JSONValue {
        var body: [String: JSONValue] = ["text": .string(text), "format": "markdown"]
        if let embeds { body["embeds"] = embeds }
        return ["method": "message", "params": ["message_id": .string(id), "log_id": .string(id), "room_id": "general",
                                                "from": ["user_id": .string(userID), "name": "Ada"], "body": .object(body)]]
    }

    private func installed(_ id: String) async {
        await eventually("message \(id) installed") { session.store.message(LogID(id)!) != nil }
    }

    func testTheEchoBeforeTheResultTakesThePendingRowsPlaceAndKeepsItsID() async throws {
        session.post("hello", in: "general")
        _ = await sent(socket, count: 3)
        XCTAssertEqual(rows(), ["pending-q-c3 hello (sending)"])

        await socket.deliver(echo("400", "hello"))
        await installed("400")
        XCTAssertEqual(rows(), ["pending-q-c3 hello (logged 400)"], "one row, the logged message under the queued row's id")

        await socket.deliver(["id": "q-c3", "result": ["message_id": "400"]])
        await eventually("result applied") { session.inFlight == nil }
        XCTAssertEqual(rows(), ["pending-q-c3 hello (logged 400)"])
        XCTAssertEqual(session.timelineItems("general", lineBefore: nil).compactMap(\.storedMessage).map(\.messageID.text), ["400"])

        session.show("general", false)
        XCTAssertEqual(rows(), ["400 hello"], "off screen, the message takes its own id")
        XCTAssertTrue(session.outbox.isEmpty)
    }

    func testTheResultBeforeTheEchoKeepsTheRowUntilTheSnapshotArrives() async throws {
        session.post("hello", in: "general")
        _ = await sent(socket, count: 3)
        await socket.deliver(["id": "q-c3", "result": ["message_id": "400"]])
        await eventually("result applied") { session.outbox.first?.state == .sent(LogID("400")!) }
        XCTAssertEqual(rows(), ["pending-q-c3 hello (sent, awaiting 400)"], "never a frame with neither row")
        XCTAssertEqual(session.timelineItems("general", lineBefore: nil).compactMap(\.storedMessage).count, 0, "nothing to act on yet")

        await socket.deliver(echo("400", "hello"))
        await installed("400")
        XCTAssertEqual(rows(), ["pending-q-c3 hello (logged 400)"])
        session.show("general", false)
        XCTAssertEqual(rows(), ["400 hello"])
    }

    func testAnEchoThatIsNotTheMessageInFlightStaysItsOwnRowUntilTheResultSaysWhichIs() async throws {
        session.post("hello", in: "general")
        _ = await sent(socket, count: 3)
        await socket.deliver(echo("400", "other words"))
        await installed("400")
        XCTAssertEqual(rows(), ["400 other words", "pending-q-c3 hello (sending)"], "another device's message is not the echo")

        await socket.deliver(["id": "q-c3", "result": ["message_id": "401"]])
        await eventually("result applied") { session.outbox.first?.state == .sent(LogID("401")!) }
        XCTAssertEqual(rows(), ["400 other words", "pending-q-c3 hello (sent, awaiting 401)"])
        await socket.deliver(echo("401", "hello"))
        await installed("401")
        XCTAssertEqual(rows(), ["400 other words", "pending-q-c3 hello (logged 401)"])
    }

    func testAMessageStartingWithASlashReadsAsSentAndItsEchoIsKnown() async throws {
        session.post("//status is a word here", in: "general")
        _ = await sent(socket, count: 3)
        XCTAssertEqual(rows(), ["pending-q-c3 /status is a word here (sending)"], "the first slash goes, as send drops it (§4.1)")
        await socket.deliver(echo("400", "/status is a word here"))
        await installed("400")
        XCTAssertEqual(rows(), ["pending-q-c3 /status is a word here (logged 400)"])
    }

    func testARefusedMessageStaysNotSentThenRetriesUnderTheSameRow() async throws {
        session.post("hello", in: "general")
        _ = await sent(socket, count: 3)
        await socket.deliver(["id": "q-c3", "error": ["code": -32003, "message": "Too large"]])
        await eventually("failed") { session.outbox.first?.state == .failed("Too long for this server.") }
        XCTAssertEqual(rows(), ["pending-q-c3 hello (not sent: Too long for this server.)"])
        XCTAssertEqual(session.timelineItems("general", lineBefore: nil).compactMap(\.storedMessage).count, 0)

        session.retry("q-c3")
        _ = await sent(socket, count: 4)
        XCTAssertEqual(rows(), ["pending-q-c3 hello (sending)"])
        await socket.deliver(["id": "q-c3", "result": ["message_id": "400"]])
        await socket.deliver(echo("400", "hello"))
        await installed("400")
        XCTAssertEqual(rows(), ["pending-q-c3 hello (logged 400)"])
    }

    func testTheQueuedRowReadsAsTheMessageWillAndLendsItsFileToThePendingUpload() async throws {
        let photo = Attachment(fileURL: URL(filePath: "/tmp/photo.jpg"), title: "photo.jpg", contentType: "image/jpeg", byteCount: 10,
                               pixelWidth: 1200, pixelHeight: 800)
        session.post("look @Bob", in: "general", replyTo: LogID("100"), mentions: ["bob"], attachments: [photo])
        _ = await sent(socket, count: 3)
        let items = session.timelineItems("general", lineBefore: nil)
        guard case .message(let local, _, let pending)? = items.last else { return XCTFail("a message row") }
        XCTAssertEqual(local.from.userID, "ada")
        XCTAssertEqual(local.replyTo, LogID("100"))
        XCTAssertEqual(local.mentionIDs, ["bob"])
        XCTAssertEqual(local.embedList.map(\.upload), [.pending])
        XCTAssertEqual(local.messageID, local.logID, "a creation, never shown as edited")
        XCTAssertEqual(items.map(\.id).first?.hasPrefix("day-"), true, "its day pill, as a logged message gets")
        let row = MessageRowModel(local, in: session, pending: pending)
        XCTAssertEqual(row.statusLine, "Sending…")
        XCTAssertEqual(row.localFiles, [0: photo])
        XCTAssertEqual(row.spoken(reminderDue: nil, now: .now).contains("look @Bob, Sending…, replying to"), false)
        XCTAssertTrue(row.spoken(reminderDue: nil, now: .now).contains(", look @Bob, Sending…, "))

        await socket.deliver(["id": "q-c3", "result": ["message_id": "400", "embeds": [["embed_id": "e1", "kind": "upload", "write_url": "https://chat.example/write/1"]]]])
        await socket.deliver(echo("400", "look @Bob", embeds: [["embed_id": "e1", "kind": "upload", "title": "photo.jpg"]]))
        await installed("400")
        guard case .message(let logged, _, let handed)? = session.timelineItems("general", lineBefore: nil).last else { return XCTFail("a message row") }
        let shown = MessageRowModel(logged, in: session, pending: handed)
        XCTAssertNil(shown.statusLine)
        XCTAssertEqual(shown.localFiles, [0: photo], "the picture stays while the write lands")
        XCTAssertEqual(shown.embeds.map(\.embed.upload), [.pending])
    }

    // MARK: Edits

    private func original() async throws -> MessageSnapshot {
        await socket.deliver(echo("200", "helo"))
        await installed("200")
        return try XCTUnwrap(session.store.message(LogID("200")!))
    }

    private func texts() -> [String] { session.timeline("general").map { "\($0.plainText)\($0.isEdited ? " (edited)" : "")" } }

    func testAnEditShowsAtOnceAndTheEchoBeforeTheResultSettlesIt() async throws {
        let message = try await original()
        let saving = Task { try await session.edit(MessageEdit(message), text: "hello", mentions: []) }
        _ = await sent(socket, count: 3)
        XCTAssertEqual(texts(), ["hello"], "shown as sent, not yet marked edited")
        XCTAssertEqual(session.store.message(LogID("200")!)?.plainText, "helo", "the store keeps the server's snapshot")

        await socket.deliver(["method": "message", "params": ["message_id": "200", "log_id": "300", "room_id": "general",
                                                              "from": ["user_id": "ada", "name": "Ada"], "body": ["text": "hello", "format": "markdown"]]])
        await eventually("echo settles the edit") { session.pendingEdits.isEmpty }
        XCTAssertEqual(texts(), ["hello (edited)"])
        await socket.deliver(["id": "c3", "result": ["message_id": "200"]])
        try await saving.value
        XCTAssertEqual(texts(), ["hello (edited)"])
    }

    func testAnEditResultBeforeItsEchoKeepsTheTextShown() async throws {
        let message = try await original()
        let saving = Task { try await session.edit(MessageEdit(message), text: "hello", mentions: []) }
        _ = await sent(socket, count: 3)
        await socket.deliver(["id": "c3", "result": ["message_id": "200"]])
        try await saving.value
        XCTAssertEqual(texts(), ["hello"], "the result alone does not take the text back")
        XCTAssertEqual(session.pendingEdits.count, 1)

        await socket.deliver(["method": "message", "params": ["message_id": "200", "log_id": "300", "room_id": "general",
                                                              "from": ["user_id": "ada", "name": "Ada"], "body": ["text": "hello", "format": "markdown"]]])
        await eventually("echo settles the edit") { session.pendingEdits.isEmpty }
        XCTAssertEqual(texts(), ["hello (edited)"])
    }

    func testARefusedEditRevertsAndThrows() async throws {
        let message = try await original()
        let saving = Task { try await session.edit(MessageEdit(message), text: "hello", mentions: []) }
        _ = await sent(socket, count: 3)
        XCTAssertEqual(texts(), ["hello"])
        await socket.deliver(["id": "c3", "error": ["code": -32001, "message": "Not yours"]])
        do {
            try await saving.value
            XCTFail("expected the refusal")
        } catch let error as RPCError {
            XCTAssertEqual(error.message, "Not yours")
        }
        XCTAssertEqual(texts(), ["helo"])
        XCTAssertTrue(session.pendingEdits.isEmpty)
    }

    func testRemovingAReplyShowsAtOnceToo() async throws {
        await socket.deliver(["method": "message", "params": ["message_id": "200", "log_id": "200", "room_id": "general",
                                                              "from": ["user_id": "ada", "name": "Ada"], "body": ["text": "helo"], "reply_to": ["message_id": "150"]]])
        await installed("200")
        let message = try XCTUnwrap(session.store.message(LogID("200")!))
        let saving = Task { try await session.removeReply(from: message) }
        _ = await sent(socket, count: 3)
        XCTAssertEqual(session.timeline("general").map(\.replyTo), [nil])
        await socket.deliver(["id": "c3", "result": ["message_id": "200"]])
        try await saving.value
        await socket.deliver(["method": "message", "params": ["message_id": "200", "log_id": "300", "room_id": "general",
                                                              "from": ["user_id": "ada", "name": "Ada"], "body": ["text": "helo"]]])
        await eventually("echo settles the edit") { session.pendingEdits.isEmpty }
        XCTAssertEqual(session.timeline("general").map(\.replyTo), [nil])
    }
}
