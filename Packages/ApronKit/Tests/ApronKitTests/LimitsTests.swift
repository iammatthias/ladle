@testable import ApronKit
import Foundation
import XCTest

final class LimitsTests: ScriptedSessionCase {
    static let upload: JSONValue = ["room_id": "general", "body": ["text": "look", "embeds": [["kind": "upload", "title": "a.png"]]]]
    static let kept: JSONValue = ["room_id": "general", "body": ["text": "look", "embeds": [["kind": "upload", "embed_id": "e1"]]]]

    func testWhatARefusalHoldsBack() {
        XCTAssertEqual(LimitScope(refused: "reactions", params: [:], category: "write"), .write)
        XCTAssertEqual(LimitScope(refused: "command", params: [:], category: "write"), nil, "a command may do anything")
        XCTAssertEqual(LimitScope(refused: "message", params: Self.upload, category: "upload"), .upload)
        XCTAssertEqual(LimitScope(refused: "message", params: Self.kept, category: "upload"), .message, "a kept upload adds none")
        XCTAssertEqual(LimitScope(refused: "message", params: [:], category: nil), .message)
        XCTAssertEqual(LimitScope(refused: "history", params: [:], category: "read"), .history)
        XCTAssertEqual(LimitScope(refused: "room_join", params: [:], category: nil), nil)

        XCTAssertEqual(["message", "reactions", "room_join", "room_leave", "room_set", "command", "me"].filter { LimitScope.write.holds($0, params: [:]) },
                       ["message", "reactions", "room_join", "room_leave", "room_set"])
        XCTAssertTrue(LimitScope.upload.holds("command", params: Self.upload))
        XCTAssertFalse(LimitScope.upload.holds("message", params: ["body": ["text": "hi"]]))
        XCTAssertFalse(LimitScope.history.holds("history", params: [:]), "history waits where it loads")
    }

    func testAWaitReadsAsTheWebSaysIt() {
        XCTAssertEqual([0.2, 17, 59.5, 60, 125].map { WaitWords.countdown($0, long: false) }, ["1s", "17s", "1:00", "1:00", "2:05"])
        XCTAssertEqual([30, 3600, 11_520].map { WaitWords.countdown($0, long: true) }, ["1m", "1h 0m", "3h 12m"])
        XCTAssertEqual(WaitWords.spoken(17, long: false), "17 seconds")
        XCTAssertEqual(WaitWords.spoken(1, long: false), "1 second")
        XCTAssertEqual(WaitWords.spoken(11_520, long: true), "3 hours 12 minutes")
        XCTAssertEqual(WaitWords.spoken(7200, long: true), "2 hours")
        XCTAssertEqual([45, 150, 7200].map(WaitWords.retryAfter), ["45s", "3m", "2h"])
        XCTAssertEqual(RPCError(code: -32002, message: "Posting limit reached", data: ["retry_after": 45]).userFacing,
                       "Posting limit reached. Try again in 45s.")
        XCTAssertEqual(RPCError(code: -32002, message: "Slow down!", data: ["retry_after": 120]).userFacing, "Slow down! Try again in 2m.")
        XCTAssertEqual(RPCError(code: -32001, message: "No").userFacing, "No")
        XCTAssertEqual(RPCError(code: -32001, message: "").userFacing, "Request failed (-32001).")
        XCTAssertEqual(WaitWords.notice(.write)?.title, "Sending is paused.")
        XCTAssertEqual(WaitWords.notice(.upload)?.lead, "Uploads resume in")
    }

    private func signedIn(capabilities: [String] = ["history", "rooms", "reactions", "ext:limits"]) async throws -> FakeTransport {
        let socket = queueTransport(capabilities: capabilities)
        session.start()
        try await signIn(socket)
        return socket
    }

    func testDuringAWriteWaitReactionsJoinsAndLeavesAreRefusedInTheServersWords() async throws {
        let socket = try await signedIn()
        let reacting = Task { try await session.toggleReaction("👍", on: LogID("100")!) }
        _ = await sent(socket, count: 3)
        await socket.deliver(["id": "c3", "error": ["code": -32002, "message": "Posting limit reached",
                                                    "data": ["retry_after": 30, "ext": ["limits": "write"]]]])
        _ = try? await reacting.value
        XCTAssertEqual(session.sendWait?.until, now.addingTimeInterval(30))
        XCTAssertEqual(session.sendWait?.isLong, false)

        advance(12)
        let session = session!
        for attempt in [{ try await session.join("random") }, { try await session.leave("general") },
                        { try await session.toggleReaction("👍", on: LogID("100")!) }] as [@MainActor () async throws -> Void] {
            do {
                try await attempt()
                XCTFail("held back")
            } catch let error as RPCError {
                XCTAssertEqual(error.userFacing, "Posting limit reached. Try again in 18s.")
            }
        }
        let log = await socket.sentLog
        XCTAssertEqual(log.count, 3, "nothing went")

        advance(19)
        XCTAssertNil(session.sendWait)
        let joining = Task { try await session.join("random") }
        _ = await sent(socket, count: 4)
        await socket.deliver(["id": "c4", "result": [:]])
        try await joining.value
    }

    func testARefusedMessageHoldsBackSendingAsSendingIsPaused() async throws {
        let socket = try await signedIn(capabilities: ["history", "rooms", "reactions"])
        let sending = Task { try await session.send("hi", in: "general") }
        _ = await sent(socket, count: 3)
        await socket.deliver(["id": "c3", "error": ["code": -32002, "message": "Too fast", "data": ["retry_after": 4000, "ext": ["limits": "write"]]]])
        _ = try? await sending.value
        XCTAssertNotNil(session.wait(.message), "without ext:limits the category does not count")
        XCTAssertNil(session.wait(.write))
        XCTAssertEqual(session.sendWait?.isLong, true, "an hour or more counts down in minutes")
        do {
            try await session.send("again", in: "general")
            XCTFail("held back")
        } catch let error as RPCError {
            XCTAssertEqual(error.userFacing, "Sending is paused. Try again in 2h.")
        }
        let join = Task { try await session.join("random") }
        _ = await sent(socket, count: 4)
        await socket.deliver(["id": "c4", "result": [:]])
        try await join.value
    }

    func testAnUploadWaitHoldsBackOnlyMessagesWithFiles() async throws {
        let socket = try await signedIn()
        let photo = Attachment(fileURL: URL(filePath: "/tmp/a.png"), title: "a.png", contentType: "image/png", byteCount: 10)
        let sending = Task { try await session.send("look", in: "general", attachments: [photo]) }
        _ = await sent(socket, count: 3)
        await socket.deliver(["id": "c3", "error": ["code": -32002, "message": "Daily upload limit reached",
                                                    "data": ["retry_after": 600, "ext": ["limits": "upload"]]]])
        _ = try? await sending.value
        XCTAssertNil(session.composerWait(withFiles: false))
        XCTAssertEqual(session.composerWait(withFiles: true)?.message, "Daily upload limit reached")
        let text = Task { try await session.send("anyway", in: "general") }
        _ = await sent(socket, count: 4)
        await socket.deliver(["id": "c4", "result": ["message_id": "200"]])
        _ = try await text.value
    }

    func testAnotherAccountStartsWithoutWaits() async throws {
        let socket = try await signedIn()
        let reacting = Task { try await session.toggleReaction("👍", on: LogID("100")!) }
        _ = await sent(socket, count: 3)
        await socket.deliver(["id": "c3", "error": ["code": -32002, "message": "Posting limit reached",
                                                    "data": ["retry_after": 30, "ext": ["limits": "write"]]]])
        _ = try? await reacting.value
        XCTAssertNotNil(session.sendWait)
        await session.signOut()
        XCTAssertNil(session.sendWait)
    }
}
