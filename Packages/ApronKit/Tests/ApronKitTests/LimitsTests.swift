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
        XCTAssertEqual(LimitScope(refused: "room_list", params: [:], category: "read"), .history, "a read wait covers room listing")
        XCTAssertEqual(LimitScope(refused: "room_list", params: [:], category: nil), nil)
        XCTAssertEqual(["history", "room_list", "message"].filter { LimitScope.history.holds($0, params: [:]) }, ["history", "room_list"])
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

    func testARefusedHistoryPageIsNotAskedForAgainUntilItsWaitIsOver() async throws {
        let socket = try await signedIn()
        let opening = Task { try await session.open("general") }
        _ = await sent(socket, count: 3)
        await socket.deliver(["id": "c3", "error": ["code": -32002, "message": "History request limit reached",
                                                    "data": ["retry_after": 30, "ext": ["limits": "read"]]]])
        _ = try? await opening.value

        advance(12)
        do {
            try await session.open("general")
            XCTFail("held back")
        } catch let error as RPCError {
            XCTAssertEqual(error.userFacing, "History request limit reached. Try again in 18s.")
        }
        let log = await socket.sentLog
        XCTAssertEqual(log.count, 3, "nothing went")

        advance(19)
        let again = Task { try await session.open("general") }
        let history = await sent(socket, count: 4)
        XCTAssertEqual(history[3], #"{"id":"c4","method":"history","params":{"limit":50,"room_id":"general"}}"#)
        await socket.deliver(["id": "c4", "result": ["entries": [], "more": false]])
        _ = await sent(socket, count: 5)
        await socket.deliver(["id": "c5", "result": ["not_joined": []]])
        try await again.value
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

    func testOnlyReadsReactionsAndEditsWaitOutAShortRefusal() {
        XCTAssertEqual(["history", "room_list", "reactions", "room_join", "command", "me"].filter { ShortWait.waitsOut($0, [:]) },
                       ["history", "room_list", "reactions"])
        XCTAssertTrue(ShortWait.waitsOut("message", ["message_id": "100", "room_id": "general", "deleted": true]), "an edit or delete")
        XCTAssertFalse(ShortWait.waitsOut("message", ["room_id": "general", "body": ["text": "hi"]]), "a post keeps the outbox's own logic")
    }

    /// Waits for the clock's next sleep, checks how long it is, and lets it end.
    private func releaseSleep(_ index: Int, of delay: Duration) async {
        await eventually("sleep \(index)") { clock.recorded.count > index }
        XCTAssertEqual(clock.recorded[index], delay)
        clock.release()
    }

    func testAShortHistoryWaitIsWaitedOutAndTheSameRequestSentAgain() async throws {
        let socket = try await signedIn()
        let slept = clock.recorded.count
        let opening = Task { try await session.open("general") }
        let first = await sent(socket, count: 3)
        XCTAssertEqual(first[2], #"{"id":"c3","method":"history","params":{"limit":50,"room_id":"general"}}"#)
        await socket.deliver(["id": "c3", "error": ["code": -32002, "message": "History request limit reached",
                                                    "data": ["retry_after": 2, "ext": ["limits": "read"]]]])
        await releaseSleep(slept, of: .seconds(2))
        let again = await sent(socket, count: 4)
        XCTAssertEqual(again[3], #"{"id":"c3","method":"history","params":{"limit":50,"room_id":"general"}}"#, "the same id")
        await socket.deliver(["id": "c3", "result": ["messages": [
            ["message_id": "100", "log_id": "100", "room_id": "general", "from": ["user_id": "bob"], "body": ["text": "hi"]],
        ], "more": false]])
        _ = await sent(socket, count: 5)
        await socket.deliver(["id": "c4", "result": ["not_joined": []]])
        try await opening.value
        XCTAssertEqual(session.timeline("general").map(\.messageID), [LogID("100")!])
        XCTAssertNil(session.wait(.history), "a wait waited out holds nothing back")
    }

    func testAShortWaitIsResentTwiceAtMostThenShows() async throws {
        let socket = try await signedIn()
        let slept = clock.recorded.count
        let reacting = Task { try await session.toggleReaction("👍", on: LogID("100")!) }
        let refusal: JSONValue = ["code": -32002, "message": "Posting limit reached", "data": ["retry_after": 1]]
        for (index, count) in [3, 4, 5].enumerated() {
            let log = await sent(socket, count: count)
            XCTAssertEqual(log[count - 1], #"{"id":"c3","method":"reactions","params":{"emojis":["👍"],"message_id":"100"}}"#)
            await socket.deliver(["id": "c3", "error": refusal])
            if index < 2 { await releaseSleep(slept + index, of: .seconds(1)) }
        }
        do {
            try await reacting.value
            XCTFail("refused")
        } catch let error as RPCError {
            XCTAssertEqual(error.userFacing, "Posting limit reached. Try again in 1s.")
        }
        let log = await socket.sentLog
        XCTAssertEqual(log.count, 5, "the first send and two more")
        XCTAssertEqual(clock.recorded.count, slept + 2)
    }

    func testALongerWaitShowsAtOnce() async throws {
        let socket = try await signedIn()
        let slept = clock.recorded.count
        let opening = Task { try await session.open("general") }
        _ = await sent(socket, count: 3)
        await socket.deliver(["id": "c3", "error": ["code": -32002, "message": "History request limit reached", "data": ["retry_after": 6]]])
        do {
            try await opening.value
            XCTFail("refused")
        } catch let error as RPCError {
            XCTAssertEqual(error.userFacing, "History request limit reached. Try again in 6s.")
        }
        XCTAssertEqual(clock.recorded.count, slept, "nothing waited")
        XCTAssertEqual(session.wait(.history)?.until, now.addingTimeInterval(6))
    }

    func testAPostRefusedForAMomentIsNotSentAgainHere() async throws {
        let socket = try await signedIn(capabilities: ["history", "rooms", "reactions"])
        let slept = clock.recorded.count
        let sending = Task { try await session.send("hi", in: "general") }
        let log = await sent(socket, count: 3)
        XCTAssertTrue(log[2].contains(#""method":"message""#))
        await socket.deliver(["id": "c3", "error": ["code": -32002, "message": "Too fast", "data": ["retry_after": 1]]])
        _ = try? await sending.value
        XCTAssertNotNil(session.wait(.message), "the outbox sees sending paused")
        XCTAssertFalse(clock.recorded.dropFirst(slept).contains(.seconds(1)), "not waited out at the request")
        let after = await socket.sentLog
        XCTAssertEqual(after.count, 3)
    }

    func testAReconnectDuringTheWaitFailsTheRequest() async throws {
        let socket = try await signedIn()
        let slept = clock.recorded.count
        let opening = Task { try await session.open("general") }
        _ = await sent(socket, count: 3)
        await socket.deliver(["id": "c3", "error": ["code": -32002, "message": "History request limit reached", "data": ["retry_after": 3]]])
        await eventually("waiting") { clock.recorded.count > slept }
        await socket.dropFromServer()
        await releaseSleep(slept, of: .seconds(3))
        do {
            try await opening.value
            XCTFail("failed")
        } catch let error as Connection.Failure {
            XCTAssertEqual(error, .closed)
        }
        let log = await socket.sentLog
        XCTAssertEqual(log.count, 3, "nothing resent on the old connection")
    }

    /// Opens general with a newest page that says more is older, as a guest signed in by `signIn`.
    private func openWithOlder(_ socket: FakeTransport) async throws {
        let opening = Task { try await session.open("general") }
        _ = await sent(socket, count: 3)
        await socket.deliver(["id": "c3", "result": ["messages": [
            ["message_id": "300", "log_id": "300", "room_id": "general", "from": ["user_id": "bob"], "body": ["text": "newest"]],
        ], "first_log_id": "300", "last_log_id": "300", "latest_log_id": "300", "more": true]])
        _ = await sent(socket, count: 4)
        await socket.deliver(["id": "c4", "result": ["not_joined": []]])
        try await opening.value
        XCTAssertTrue(session.canLoadOlder("general"))
        XCTAssertNil(session.historyEnd(of: "general"))
    }

    func testAGuestRefusedOlderHistoryReachesItsEndAndAsksToSignIn() async throws {
        let socket = try await signedIn()
        try await openWithOlder(socket)
        let older = Task { try await session.loadOlder("general") }
        let log = await sent(socket, count: 5)
        XCTAssertEqual(log[4], #"{"id":"c5","method":"history","params":{"before":"299","limit":50,"room_id":"general"}}"#)
        await socket.deliver(["id": "c5", "error": ["code": -32001, "message": "Sign in to load older history"]])
        try await older.value
        XCTAssertEqual(session.historyEnd(of: "general"), .signInForOlder)
        XCTAssertFalse(session.canLoadOlder("general"))
        XCTAssertTrue(session.hasOlder("general"))
        XCTAssertNil(session.wait(.history))
        try await session.loadOlder("general")
        let after = await socket.sentLog
        XCTAssertEqual(after.count, 5, "paging stops for the room")
    }

    func testAnAccountRefusedOlderHistorySeesTheError() async throws {
        let socket = queueTransport(capabilities: ["history", "rooms"])
        session.start()
        await eventually("signed out") { session.status == .signedOut }
        let signIn = Task { try await session.signIn(.token("t1")) }
        _ = await sent(socket, count: 2)
        await socket.deliver(["id": "c1", "result": ["you": ["user_id": "ada", "name": "Ada"]]])
        await socket.deliver(["id": "c2", "result": ["joined": [["room_id": "general", "log_id": "100", "title": "General", "latest_log_id": "300"]]]])
        _ = try await signIn.value
        try await openWithOlder(socket)
        let older = Task { try await session.loadOlder("general") }
        _ = await sent(socket, count: 5)
        await socket.deliver(["id": "c5", "error": ["code": -32001, "message": "No"]])
        do {
            try await older.value
            XCTFail("refused")
        } catch let error as RPCError {
            XCTAssertEqual(error.message, "No")
        }
        XCTAssertNil(session.historyEnd(of: "general"))
        XCTAssertTrue(session.canLoadOlder("general"))
    }
}
