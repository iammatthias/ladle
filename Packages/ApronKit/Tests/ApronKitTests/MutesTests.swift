@testable import ApronKit
import Foundation
import Synchronization
import XCTest

/// A wall clock that moves only when a test moves it.
final class WallClock: Sendable {
    private let date = Mutex(Date(timeIntervalSince1970: 1_798_000_000))
    var now: Date { date.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { date.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

/// A session over a scripted transport, for the `status` tests (mutes, idle, limits).
@MainActor
class ScriptedSessionCase: XCTestCase {
    let transports = Transports()
    let clock = FakeClock()
    /// The wall clock the session reads; tests move it.
    let wallClock = WallClock()
    var session: ServerSession!

    func makeSession(_ change: (inout ServerSession.Environment) -> Void = { _ in }) {
        let counter = Mutex(0)
        let transports = transports, clock = clock, wallClock = wallClock
        var environment = ServerSession.Environment(
            makeTransport: { _ in transports.next() },
            sleep: { try await clock.sleep($0) },
            jitter: { 1 },
            makeRequestID: { counter.withLock { $0 += 1; return "c\($0)" } },
            now: { wallClock.now }
        )
        change(&environment)
        let record = ServerRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000000009")!, url: URL(string: "wss://chat.example/ws")!)
        session = ServerSession(record: record, tokens: InMemoryTokenStore(), environment: environment)
    }

    override func setUp() async throws { makeSession() }

    override func tearDown() async throws { await session.stop() }

    var now: Date { wallClock.now }

    func advance(_ seconds: TimeInterval) { wallClock.advance(seconds) }

    func queueTransport(capabilities: [String]) -> FakeTransport {
        let transport = FakeTransport()
        transports.queued.withLock { $0.append(transport) }
        let params: JSONValue = ["apron": 9, "auth": ["guest"], "capabilities": .array(capabilities.map(JSONValue.string))]
        Task { await transport.deliver(["method": "server", "params": params]) }
        return transport
    }

    func sent(_ transport: FakeTransport, count: Int) async -> [String] {
        await eventually("\(count) frames") { await transport.sentLog.count >= count }
        return await Array(transport.sentLog.prefix(count))
    }

    /// Signs in as Ada, a member of general and of its thread ideas.
    func signIn(_ transport: FakeTransport) async throws {
        await eventually("signed out") { session.status == .signedOut }
        let signIn = Task { try await session.signIn(.guest(name: nil)) }
        _ = await sent(transport, count: 2)
        await transport.deliver(["id": "c1", "result": ["you": ["user_id": "ada", "name": "Ada"], "token": "t1"]])
        await transport.deliver(["id": "c2", "result": ["joined": [
            ["room_id": "general", "log_id": "100", "title": "General", "latest_log_id": "100", "history_log_id": "100"],
            ["room_id": "ideas", "log_id": "101", "title": "Ideas", "parent_room_id": "general", "latest_log_id": "101", "history_log_id": "101"],
            ["room_id": "random", "log_id": "102", "title": "Random", "latest_log_id": "102", "history_log_id": "102"],
        ]]])
        _ = try await signIn.value
    }

    func status(_ params: JSONValue) -> JSONValue { ["method": "status", "params": params] }
}

final class MutesTests: ScriptedSessionCase {
    let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    let british = Locale(identifier: "en_GB")

    func date(_ text: String) -> Date { try! Date(text, strategy: .iso8601) }

    func testThePauseMenuIsAnHourEightHoursTheNextNineOClockOrUntilResumed() {
        let afternoon = MuteChoice.pause(now: date("2026-10-30T14:30:00Z"), calendar: utc, locale: british)
        XCTAssertEqual(afternoon.map(\.title), ["For 1 hour", "For 8 hours", "Until tomorrow", "Until I resume"])
        XCTAssertEqual(afternoon.map(\.hint), ["until 15:30", "until 22:30", "9:00", nil])
        XCTAssertEqual(afternoon[2].end, .at(date("2026-10-31T09:00:00Z")))
        XCTAssertEqual(afternoon[3].end, .untilChanged)

        let early = MuteChoice.pause(now: date("2026-10-30T06:10:00Z"), calendar: utc, locale: british)
        XCTAssertEqual(early[2].title, "Until this morning")
        XCTAssertEqual(early[2].end, .at(date("2026-10-30T09:00:00Z")))
    }

    func testARoomMutesForOneTwoOrEightHoursOrUntilUnmuted() {
        let choices = MuteChoice.room(now: date("2026-10-30T14:30:00Z"), calendar: utc, locale: british)
        XCTAssertEqual(choices.map(\.title), ["For 1 hour", "For 2 hours", "For 8 hours", "Until I unmute"])
        XCTAssertEqual(choices.map(\.hint), ["until 15:30", "until 16:30", "until 22:30", nil])
    }

    func testAMuteGoesAsWholeSecondsLeftOrTrue() {
        let start = date("2026-10-30T14:30:00Z")
        XCTAssertEqual(MuteEnd.at(start.addingTimeInterval(3600)).wire(now: start), .number("3600"))
        XCTAssertEqual(MuteEnd.at(start.addingTimeInterval(0.2)).wire(now: start), .number("1"), "at least a second")
        XCTAssertEqual(MuteEnd.at(start.addingTimeInterval(-5)).wire(now: start), .number("1"))
        XCTAssertEqual(MuteEnd.untilChanged.wire(now: start), .bool(true))
    }

    func testWhenAPauseEndsInWords() {
        let start = date("2026-10-30T14:30:00Z")
        func words(_ end: MuteEnd) -> String { end.words(now: start, calendar: utc, locale: british) }
        XCTAssertEqual(words(.at(date("2026-10-30T22:30:00Z"))), "until 22:30")
        XCTAssertEqual(words(.at(date("2026-10-31T09:00:00Z"))), "until tomorrow 9:00")
        XCTAssertEqual(words(.at(date("2026-11-02T09:00:00Z"))), "until Mon 9:00")
        XCTAssertEqual(words(.untilChanged), "until you resume")
        XCTAssertEqual(MuteEnd.untilChanged.words(now: start, open: "until you unmute"), "until you unmute")
    }

    func testAPauseAndRoomMutesAreWhatTheServersStatusSays() async throws {
        let socket = queueTransport(capabilities: ["history", "rooms", "status"])
        session.start()
        try await signIn(socket)
        XCTAssertTrue(session.mayMute)
        XCTAssertNil(session.pause)

        await socket.deliver(status(["mute": 3600]))
        await socket.deliver(status(["room_id": "general", "mute": true]))
        await socket.deliver(status(["room_id": "random", "mute": 60]))
        await socket.deliver(status(["room_id": 5, "mute": true]))
        await socket.deliver(status(["mute": "forever"]))
        await eventually("three applied") { session.roomMutes.count == 2 }
        XCTAssertEqual(session.pause, .at(now.addingTimeInterval(3600)), "an invalid mute changes nothing")
        XCTAssertEqual(session.mute(of: "general"), .own(.untilChanged))
        XCTAssertEqual(session.mute(of: "ideas"), .withRoom("general", .untilChanged), "a room's mute covers its threads")
        XCTAssertEqual(session.mute(of: "random"), .own(.at(now.addingTimeInterval(60))))

        advance(61)
        XCTAssertNil(session.mute(of: "random"), "a timed mute is over at its end, whatever the server says after")
        XCTAssertNotNil(session.pause)
        advance(3600)
        XCTAssertNil(session.pause)

        await socket.deliver(status(["room_id": "general", "mute": false]))
        await eventually("unmuted") { session.mute(of: "general") == nil }
        XCTAssertNil(session.mute(of: "ideas"))
    }

    func testTheProfileLineSaysPausedFirst() async throws {
        let socket = queueTransport(capabilities: ["history", "rooms", "status"])
        session.start()
        try await signIn(socket)
        XCTAssertEqual(session.profileLine, "@ada")
        await socket.deliver(status(["mute": true]))
        await eventually("paused") { session.pause != nil }
        XCTAssertEqual(session.profileLine, "Paused until you resume")
    }

    func testPausingAndMutingOnlyAsk() async throws {
        let socket = queueTransport(capabilities: ["history", "rooms", "status"])
        session.start()
        try await signIn(socket)

        let pausing = Task { try await session.setPause(.at(now.addingTimeInterval(8 * 3600))) }
        _ = await sent(socket, count: 3)
        XCTAssertNil(session.pause, "nothing changes before the server says so")
        await socket.deliver(status(["mute": 28800]))
        await socket.deliver(["id": "c3", "result": [:]])
        try await pausing.value

        let muting = Task { try await session.setMute("general", .untilChanged) }
        _ = await sent(socket, count: 4)
        await socket.deliver(["id": "c4", "result": [:]])
        try await muting.value

        let resuming = Task { try await session.setPause(nil) }
        _ = await sent(socket, count: 5)
        await socket.deliver(["id": "c5", "error": ["code": -32002, "message": "Mute changes limited", "data": ["retry_after": 30]]])
        do {
            try await resuming.value
            XCTFail("a refusal throws")
        } catch let error as RPCError {
            XCTAssertEqual(error.message, "Mute changes limited")
        }

        let log = await socket.sentLog
        XCTAssertEqual(Array(log[2...]), [
            #"{"id":"c3","method":"status","params":{"mute":28800}}"#,
            #"{"id":"c4","method":"status","params":{"mute":true,"room_id":"general"}}"#,
            #"{"id":"c5","method":"status","params":{"mute":false}}"#,
        ])
        XCTAssertNotNil(session.pause, "a refused resume leaves the pause")
    }

    func testEachSignInStartsWithoutMutes() async throws {
        let socket = queueTransport(capabilities: ["history", "rooms", "status"])
        session.start()
        try await signIn(socket)
        await socket.deliver(status(["room_id": "general", "mute": true]))
        await eventually("muted") { session.mute(of: "general") != nil }
        let next = queueTransport(capabilities: ["history", "rooms", "status"])
        await socket.dropFromServer()
        await eventually("reconnect waits") { clock.recorded.count == 1 }
        clock.release()
        await eventually("signed in again") { await next.sentLog.count >= 2 }
        await next.deliver(["id": "c3", "result": ["you": ["user_id": "ada", "name": "Ada"]]])
        await eventually("signed in") { session.status == .signedIn }
        XCTAssertNil(session.mute(of: "general"), "the server sends the mutes in effect after the result")
    }

    /// apron-web offers Pause and Mute only to a registered session: not a guest the server gave
    /// no token to sign back in with.
    func testAGuestWithoutATokenCannotMuteOrPause() async throws {
        let socket = queueTransport(capabilities: ["history", "rooms", "status"])
        session.start()
        await eventually("signed out") { session.status == .signedOut }
        let signIn = Task { try await session.signIn(.guest(name: nil)) }
        _ = await sent(socket, count: 2)
        await socket.deliver(["id": "c1", "result": ["you": ["user_id": "guest-7", "name": "Guest"]]])
        await socket.deliver(["id": "c2", "result": ["joined": []]])
        _ = try await signIn.value
        XCTAssertTrue(session.isGuest)
        XCTAssertFalse(session.resumable)
        XCTAssertFalse(session.mayMute)
    }

    func testAGuestWithATokenMayMute() async throws {
        let socket = queueTransport(capabilities: ["history", "rooms", "status"])
        session.start()
        try await signIn(socket)
        XCTAssertTrue(session.isGuest)
        XCTAssertTrue(session.resumable)
        XCTAssertTrue(session.mayMute)
        await session.signOut()
        XCTAssertFalse(session.resumable)
    }

    func testWithoutTheStatusCapabilityThereIsNoMuting() async throws {
        let socket = queueTransport(capabilities: ["history", "rooms"])
        session.start()
        try await signIn(socket)
        XCTAssertFalse(session.mayMute)
    }
}
