@testable import ApronKit
import Foundation
import XCTest

final class IdleTests: ScriptedSessionCase {
    func testAttentionGoesIdleAfterTheWaitOrInTheBackgroundAndInputEndsIt() async throws {
        let clock = wallClock
        let attention = Attention(idleAfter: .milliseconds(100), now: { clock.now })
        var changes: [Bool] = []
        attention.onChange = { idle, _ in changes.append(idle) }

        attention.input()
        XCTAssertFalse(attention.idle)
        XCTAssertEqual(attention.inputAt, now)
        await eventually("idle after the wait") { attention.idle }

        advance(30)
        attention.input()
        XCTAssertFalse(attention.idle, "input ends it at once")
        XCTAssertEqual(attention.inputAt, now)
        advance(0.5)
        attention.input()
        XCTAssertEqual(attention.inputAt, now.addingTimeInterval(-0.5), "input within a second does not restart the wait")

        attention.background()
        XCTAssertTrue(attention.idle, "in the background nobody attends a phone")
        XCTAssertEqual(changes, [true, false, true])
    }

    func testIdleGoesAsSecondsSinceInputAndBackAsFalseOneAtATime() async throws {
        let socket = queueTransport(capabilities: ["history", "rooms", "status"])
        session.start()
        try await signIn(socket)
        session.setIdle(false, inputAt: now)
        try await Task.sleep(for: .milliseconds(50))
        let attended = await socket.sentLog
        XCTAssertEqual(attended.count, 2, "a connection starts attended: nothing to say")

        session.setIdle(true, inputAt: now.addingTimeInterval(-300))
        session.setIdle(false, inputAt: nil)
        session.setIdle(true, inputAt: now.addingTimeInterval(-42))
        _ = await sent(socket, count: 3)
        try await Task.sleep(for: .milliseconds(50))
        let inFlight = await socket.sentLog
        XCTAssertEqual(inFlight.count, 3, "one at a time")
        await socket.deliver(["id": "c3", "result": [:]])
        try await Task.sleep(for: .milliseconds(50))
        let settled = await socket.sentLog
        XCTAssertEqual(settled.count, 3, "the app is idle again, as the server was told")

        session.setIdle(false, inputAt: now)
        _ = await sent(socket, count: 4)
        await socket.deliver(["id": "c4", "result": [:]])
        let log = await socket.sentLog
        XCTAssertEqual(Array(log[2...]), [
            #"{"id":"c3","method":"status","params":{"idle":300}}"#,
            #"{"id":"c4","method":"status","params":{"idle":false}}"#,
        ])
    }

    func testARefusedIdleGoesAgainAfterTheWaitWithWhatIsTrueThen() async throws {
        let socket = queueTransport(capabilities: ["history", "rooms", "status"])
        session.start()
        try await signIn(socket)
        session.setIdle(true, inputAt: now)
        _ = await sent(socket, count: 3)
        await socket.deliver(["id": "c3", "error": ["code": -32002, "message": "Idle changes limited", "data": ["retry_after": 20]]])
        await eventually("waits as asked") { clock.recorded == [.seconds(20)] }
        session.setIdle(false, inputAt: now)
        try await Task.sleep(for: .milliseconds(50))
        let held = await socket.sentLog
        XCTAssertEqual(held.count, 3, "nothing goes during the wait")
        clock.release()
        _ = await sent(socket, count: 3)
        try await Task.sleep(for: .milliseconds(50))
        let after = await socket.sentLog
        XCTAssertEqual(after.count, 3, "back before it went: the server never heard idle, so nothing to undo")

        session.setIdle(true, inputAt: now)
        _ = await sent(socket, count: 4)
        await socket.deliver(["id": "c4", "error": ["code": -32603, "message": "Internal"]])
        await eventually("backs off") { clock.recorded == [.seconds(20), .seconds(5)] }
    }

    func testAnIdleAppSaysSoOnEachNewConnection() async throws {
        let socket = queueTransport(capabilities: ["history", "rooms", "status"])
        session.start()
        session.setIdle(true, inputAt: now.addingTimeInterval(-10))
        try await signIn(socket)
        let first = await sent(socket, count: 3)
        XCTAssertEqual(first[2], #"{"id":"c3","method":"status","params":{"idle":10}}"#)
    }

    func testWithoutTheStatusCapabilityIdleSendsNothing() async throws {
        let socket = queueTransport(capabilities: ["history", "rooms"])
        session.start()
        try await signIn(socket)
        session.setIdle(true, inputAt: now)
        try await Task.sleep(for: .milliseconds(50))
        let log = await socket.sentLog
        XCTAssertEqual(log.count, 2)
    }
}
