@testable import ApronKit
import Foundation
import XCTest

/// What a long room costs per timeline body: `timeline()`, `timelineItems()`, the row models of
/// a visible window, and one live message appended. Skipped unless `LADLE_BENCH` is set, since
/// the numbers mean nothing in a shared test run; run it alone:
///
///     LADLE_BENCH=1 swift test --package-path Packages/ApronKit --filter TimelineBenchmark 2>&1 | grep bench
///
/// Each figure is the median of `rounds` timed calls after one warm-up, with its spread
/// (min…max), on a session fed one history page of `count` messages: markdown text, a reaction
/// on every tenth, a reply on every seventh, and a few threads.
@MainActor
final class TimelineBenchmark: ScriptedSessionCase {
    private var socket: FakeTransport!

    override func setUp() async throws {
        // The session first: XCTest runs tearDown after a skip, and that stops the session.
        try await super.setUp()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LADLE_BENCH"] != nil, "set LADLE_BENCH=1 to run the timeline benchmark")
    }

    private func fill(_ count: Int) async throws {
        makeSession { $0.pageSize = count }
        socket = queueTransport(capabilities: ["history", "edit", "rooms", "reactions"])
        session.start()
        try await signIn(socket)
        let opening = Task { try await session.open("general") }
        _ = await sent(socket, count: 3)
        var messages: [JSONValue] = []
        var reactions: [JSONValue] = []
        let authors = ["ada", "bram", "chiara", "sam", "eunji"]
        let base = 1_793_000_000_000
        for n in 0 ..< count {
            let id = String(base + n * 20_000)
            var params: [String: JSONValue] = [
                "message_id": .string(id), "log_id": .string(id), "room_id": "general",
                "from": ["user_id": .string(authors[n % 5]), "name": .string(authors[n % 5].capitalized)],
                "body": ["text": .string(Self.text(n)), "format": "markdown"],
            ]
            if n % 7 == 3, n > 0 { params["reply_to"] = ["message_id": .string(String(base + (n - 1) * 20_000))] }
            messages.append(.object(params))
            if n % 10 == 0 {
                reactions.append(["log_id": .string(String(base + n * 20_000 + 1)), "message_id": .string(id), "room_id": "general",
                                  "reactions": [["from": ["user_id": "bram"], "emojis": ["👍", "🎉"]]]])
            }
        }
        await socket.deliver(["id": "c3", "result": ["messages": .array(messages), "reactions": .array(reactions), "more": false]])
        try await opening.value
        var threads: [JSONValue] = []
        for t in 0 ..< 5 {
            threads.append(["room_id": .string(String(base + (t * count / 5 + 1) * 20_000 + 5)), "log_id": .string(String(base + count * 20_000)),
                            "parent_room_id": "general", "title": .string("Thread \(t)")])
        }
        await socket.deliver(["method": "room_update", "params": ["joined": .array(threads)]])
        await eventually("threads") { session.threadIDs(in: "general").count == 6 }
        XCTAssertEqual(session.timeline("general").count, count)
    }

    private static func text(_ n: Int) -> String {
        switch n % 4 {
        case 0: "Deploy **\(n)** is green, see https://git.example/ladle/pull/\(n) and `make check`"
        case 1: "- step one\n- step two for #\(n)\n- step three"
        case 2: "> quoting the plan\n\nThen we *ship* it, @Sam, by Friday."
        default: "Plain words about run \(n), nothing fancy here but enough to lay out."
        }
    }

    /// Median and spread of `rounds` timed calls, in milliseconds, after a warm-up call.
    private func time(_ label: String, rounds: Int = 15, _ work: () -> Void) {
        work()
        var samples: [Double] = []
        for _ in 0 ..< rounds {
            let start = ContinuousClock.now
            work()
            let elapsed = ContinuousClock.now - start
            samples.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
        }
        samples.sort()
        let median = samples[samples.count / 2]
        print(String(format: "bench %@: median %.2f ms (min %.2f, max %.2f, n=%d)", label, median, samples.first!, samples.last!, rounds))
    }

    private func run(_ count: Int) async throws {
        try await fill(count)
        let roomID = "general"
        time("\(count) store.messages(in:)") { _ = session.store.messages(in: roomID) }
        time("\(count) timeline()") { _ = session.timeline(roomID) }
        time("\(count) timelineItems()") { _ = session.timelineItems(roomID, lineBefore: nil) }
        time("\(count) unreadCount+mentionCount") { _ = session.unreadCount(in: roomID); _ = session.mentionCount(in: roomID) }
        let window = Array(session.timeline(roomID).suffix(40))
        time("\(count) 40 row models") { for message in window { _ = MessageRowModel(message, in: session) } }
        // What one TimelineView body asks the session for: the items with the New line, the
        // held check, the loading pill's check, the jump bar's counts, the pulse feed, the read
        // mark, and the row models of the rows on screen.
        time("\(count) one timeline body") {
            let items = session.timelineItems(roomID, lineBefore: session.newLine(in: roomID, after: nil))
            _ = session.timeline(roomID).isEmpty
            _ = session.timeline(roomID).isEmpty
            _ = session.unreadCount(in: roomID)
            _ = session.unreadCount(in: roomID)
            _ = session.mentionCount(in: roomID)
            _ = session.timeline(roomID)
            _ = session.timeline(roomID).last?.messageID
            for item in items.suffix(40) { if case .message(let message, _, _) = item { _ = MessageRowModel(message, in: session) } }
        }
        var next = 1_800_000_000_000
        time("\(count) one live message appended, then items", rounds: 10) {
            next += 1000
            let id = String(next)
            session.handle(WireNotification(method: "message", params: ["message_id": .string(id), "log_id": .string(id), "room_id": "general",
                                                                         "from": ["user_id": "ada", "name": "Ada"], "body": ["text": "ping", "format": "markdown"]]))
            _ = session.timelineItems(roomID, lineBefore: nil)
        }
    }

    func testFiveThousand() async throws { try await run(5_000) }
    func testTwentyThousand() async throws { try await run(20_000) }
}
