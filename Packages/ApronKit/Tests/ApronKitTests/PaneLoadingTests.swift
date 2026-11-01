import Foundation
import Synchronization
import XCTest
@testable import ApronKit

/// Seconds from an arbitrary start.
private func t(_ seconds: TimeInterval) -> Date { Date(timeIntervalSinceReferenceDate: 1_000 + seconds) }

final class SettleFlagTests: XCTestCase {
    private func on(_ flag: SettleFlag, at seconds: TimeInterval) -> Bool {
        var flag = flag
        flag.advance(to: t(seconds))
        return flag.isOn
    }

    func testWorkQuickerThanTheDelayShowsNothingCountedFromTheLatestStart() {
        var flag = SettleFlag()
        flag.set(true, at: t(0))
        flag.set(false, at: t(0.399))
        XCTAssertFalse(on(flag, at: 5))
        XCTAssertNil(flag.nextChange)

        flag.set(true, at: t(10))
        flag.set(true, at: t(10.3))
        XCTAssertFalse(on(flag, at: 10.399))
        XCTAssertTrue(on(flag, at: 10.4), "a repeat of the same state changes nothing")
    }

    func testOnOnceTheWorkHasGoneOnForTheDelayAndOffALingerAfterItEnds() {
        var flag = SettleFlag()
        flag.set(true, at: t(0))
        XCTAssertFalse(on(flag, at: 0.399))
        XCTAssertTrue(on(flag, at: 0.4))
        flag.set(false, at: t(1.1))
        XCTAssertTrue(on(flag, at: 1.399))
        XCTAssertFalse(on(flag, at: 1.4))
    }

    func testStaysOnForTheMinimumWhenTheWorkEndsJustAfterItShowed() {
        var flag = SettleFlag()
        flag.set(true, at: t(0))
        flag.set(false, at: t(0.45))
        XCTAssertTrue(flag.isOn)
        XCTAssertTrue(on(flag, at: 0.999))
        XCTAssertFalse(on(flag, at: 1.0), "shown at 0.4, so 600 ms later")
    }

    func testWorkInStepsReadsAsOne() {
        var flag = SettleFlag()
        flag.set(true, at: t(0))
        flag.set(false, at: t(0.4))
        flag.set(true, at: t(0.5))
        XCTAssertTrue(on(flag, at: 5.5))
        XCTAssertNil(flag.nextChange)
        flag.set(false, at: t(6))
        flag.set(true, at: t(6.25))
        XCTAssertTrue(on(flag, at: 8), "a next step within the linger keeps it on")
    }
}

final class PaneLoadingTests: XCTestCase {
    private let reconnecting = PaneLoading.Input(reconnecting: true)
    private let checking = PaneLoading.Input(paneCatchingUp: true, othersCatchingUp: true)
    private let others = PaneLoading.Input(othersCatchingUp: true)
    private let current = PaneLoading.Input()

    private func shown(_ loading: PaneLoading, at seconds: TimeInterval) -> PaneLoading.Shown {
        var loading = loading
        loading.advance(to: t(seconds))
        return loading.shown
    }

    private func assertNextChange(_ loading: PaneLoading, _ seconds: TimeInterval, line: UInt = #line) {
        XCTAssertEqual(loading.nextChange?.timeIntervalSince(t(0)) ?? -1, seconds, accuracy: 1e-9, line: line)
    }

    func testAQuickWayBackShowsNothing() {
        var loading = PaneLoading()
        loading.update(current, at: t(0))
        loading.update(reconnecting, at: t(0))
        assertNextChange(loading, 1.5)
        loading.update(checking, at: t(1.2))
        loading.update(current, at: t(1.45))
        XCTAssertEqual(shown(loading, at: 10), PaneLoading.Shown())
    }

    func testASlowWayBackReadsReconnectingThenCheckingAsOnePill() {
        var loading = PaneLoading()
        loading.update(reconnecting, at: t(0))
        loading.advance(to: t(1.5))
        assertNextChange(loading, 1.9)
        XCTAssertNil(shown(loading, at: 1.899).pill)
        loading.advance(to: t(1.9))
        XCTAssertEqual(loading.shown.pill, "Reconnecting…")

        loading.update(checking, at: t(3))
        XCTAssertEqual(loading.shown, PaneLoading.Shown(pill: "Checking for new messages…"), "never with the line")
        loading.update(others, at: t(3.2))
        assertNextChange(loading, 3.5)
        XCTAssertEqual(shown(loading, at: 3.499).pill, "Checking for new messages…")
        loading.advance(to: t(3.5))
        XCTAssertNil(loading.shown.pill)
        XCTAssertFalse(loading.shown.catchingUpLine, "the line waits its own 400 ms once the pill has gone")
        assertNextChange(loading, 3.9)
        loading.advance(to: t(3.9))
        XCTAssertEqual(loading.shown, PaneLoading.Shown(catchingUpLine: true))

        loading.update(current, at: t(5))
        XCTAssertTrue(shown(loading, at: 5.299).catchingUpLine)
        XCTAssertEqual(shown(loading, at: 5.3), PaneLoading.Shown())
    }

    func testOtherRoomsCatchingUpShowNothingInTheQuietMoments() {
        var loading = PaneLoading()
        loading.update(reconnecting, at: t(0))
        loading.update(others, at: t(0.5))
        assertNextChange(loading, 1.5)
        XCTAssertFalse(shown(loading, at: 1.899).catchingUpLine)
        XCTAssertTrue(shown(loading, at: 1.9).catchingUpLine)
    }

    func testAReconnectThatBecomesAProblemGivesThePillUpToTheBanner() {
        var loading = PaneLoading()
        loading.update(reconnecting, at: t(0))
        loading.advance(to: t(2))
        XCTAssertEqual(loading.shown.pill, "Reconnecting…")
        loading.update(current, at: t(7))
        XCTAssertEqual(shown(loading, at: 7.299).pill, "Reconnecting…", "its words stay while it lingers")
        XCTAssertNil(shown(loading, at: 7.3).pill)
    }

    func testAThreadChecksForRepliesAndLoadsEarlierReplies() {
        var loading = PaneLoading()
        loading.update(PaneLoading.Input(paneCatchingUp: true, loadingOlder: true, isThread: true), at: t(0))
        loading.advance(to: t(0.4))
        XCTAssertEqual(loading.shown, PaneLoading.Shown(pill: "Checking for new replies…", older: "Loading earlier replies…"))
    }

    func testOlderMessagesLoadingShowAtTheTopOnTheSameTiming() {
        var loading = PaneLoading()
        loading.update(PaneLoading.Input(loadingOlder: true), at: t(0))
        XCTAssertNil(shown(loading, at: 0.399).older)
        loading.advance(to: t(0.4))
        XCTAssertEqual(loading.shown, PaneLoading.Shown(older: "Loading earlier messages…"))
        loading.update(current, at: t(0.5))
        XCTAssertEqual(shown(loading, at: 0.999).older, "Loading earlier messages…")
        XCTAssertNil(shown(loading, at: 1).older)
    }
}

/// A clock that moves only when the test says, whose sleeps end once it has moved past them.
final class ManualClock: Sendable {
    private let elapsed = Mutex<TimeInterval>(0)
    let start = Date(timeIntervalSinceReferenceDate: 1_000)

    var now: Date { start.addingTimeInterval(elapsed.withLock { $0 }) }

    func sleep(_ delay: Duration) async throws {
        let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
        let deadline = elapsed.withLock { $0 } + seconds
        while elapsed.withLock({ $0 }) < deadline - 1e-9 {
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    func advance(to seconds: TimeInterval) { elapsed.withLock { $0 = seconds } }
}

@MainActor
final class PaneLoadingWatchTests: XCTestCase {
    func testTheWayBackFromADropOnTheSessionsClock() async throws {
        let clock = ManualClock()
        let transports = Transports()
        let counter = Mutex(0)
        let environment = ServerSession.Environment(
            makeTransport: { _ in transports.next() },
            sleep: { try await clock.sleep($0) },
            jitter: { 1 },
            makeRequestID: { counter.withLock { $0 += 1; return "c\($0)" } },
            makeState: { "state-1" },
            now: { clock.now }
        )
        let record = ServerRecord(id: UUID(), url: URL(string: "wss://chat.example/ws")!)
        let session = ServerSession(record: record, tokens: InMemoryTokenStore(), environment: environment)
        session.start()
        await eventually("signed out") { session.status == .signedOut }
        let first = transports.made.withLock { $0[0] }
        let signIn = Task { try await session.signIn(.guest(name: nil)) }
        await eventually("auth sent") { await first.sentLog.count == 2 }
        await first.deliver(["id": "c1", "result": ["you": ["user_id": "ada", "name": "Ada", "status": "online"], "token": "t1"]])
        await first.deliver(["id": "c2", "result": ["joined": [["room_id": "general", "log_id": "100", "latest_log_id": "104", "history_log_id": "100"]]]])
        _ = try await signIn.value
        let open = Task { try await session.open("general") }
        await eventually("history asked") { await first.sentLog.count == 3 }
        await first.deliver(["id": "c3", "result": ["messages": [], "more": false, "latest_log_id": "104", "history_log_id": "100"]])
        await eventually("threads asked") { await first.sentLog.count == 4 }
        await first.deliver(["id": "c4", "result": ["not_joined": []]])
        try await open.value

        let watch = PaneLoadingWatch(session: session, roomID: "general")
        let running = Task { await watch.run() }
        defer { running.cancel() }
        XCTAssertEqual(session.ownPresence, .online)
        await first.dropFromServer()
        await eventually("backing off") { session.status == .reconnecting(attempt: 1, delay: .seconds(1)) }
        XCTAssertEqual(session.ownPresence, .unknown, "the dashed ring while away")
        XCTAssertEqual(session.ownPresenceWords, "Reconnecting…")
        XCTAssertEqual(session.profileLine, "Reconnecting…", "the line under your name says so too")

        clock.advance(to: 1.8)
        let second = await {
            await eventually("reconnected") { transports.made.withLock { $0.count == 2 } }
            return transports.made.withLock { $0[1] }
        }()
        await eventually("resuming") { await second.sentLog.count == 2 }
        XCTAssertNil(watch.shown.pill, "quiet for 1.5 s, then 400 ms")
        clock.advance(to: 1.9)
        await eventually("reconnecting pill") { watch.shown.pill == "Reconnecting…" }

        clock.advance(to: 3)
        await second.deliver(["id": "c5", "result": ["you": ["user_id": "ada", "name": "Ada", "status": "online"]]])
        await second.deliver(["id": "c6", "result": ["joined": [["room_id": "general", "log_id": "100", "latest_log_id": "106", "history_log_id": "100"]]]])
        await eventually("catching up") { await second.sentLog.count == 3 }
        XCTAssertTrue(session.isCatchingUp("general"))
        XCTAssertEqual(session.ownPresence, .online)
        await eventually("checking pill") { watch.shown.pill == "Checking for new messages…" }

        await second.deliver(["id": "c7", "result": ["messages": [], "more": false, "latest_log_id": "106", "history_log_id": "100"]])
        await eventually("caught up") { !session.isCatchingUp("general") }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(watch.shown.pill, "Checking for new messages…", "lingers 300 ms")
        clock.advance(to: 3.3)
        await eventually("pill gone") { watch.shown.pill == nil }
        await session.stop()
    }
}
