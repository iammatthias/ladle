@testable import ApronKit
import Foundation
import Synchronization
import XCTest

/// Jumping to an old message against the real Rust server: one window request, a hole between
/// it and the newest page, and the hole filled from either side until the spans meet.
@MainActor
final class WindowIntegrationTests: XCTestCase {
    private var servers: [Aprond] = []
    private var sessions: [ServerSession] = []
    /// Every request id handed out, so a test counts what a step sent.
    private final class Requests: Sendable {
        let count = Mutex(0)
        func next() -> String { count.withLock { $0 += 1; return "c\($0)" } }
        var sent: Int { count.withLock { $0 } }
    }

    private let requests = Requests()

    override func tearDown() async throws {
        for session in sessions { await session.stop() }
        for server in servers { server.stop() }
    }

    private func session(_ record: ServerRecord) -> ServerSession {
        let requests = requests
        let environment = ServerSession.Environment(
            makeTransport: { WebSocketTransport(url: $0.url, origin: $0.origin) },
            makeRequestID: { requests.next() })
        let session = ServerSession(record: record, tokens: InMemoryTokenStore(), environment: environment)
        sessions.append(session)
        session.start()
        return session
    }

    private func texts(_ session: ServerSession) -> [String] {
        session.timeline("general").compactMap { $0.body?["text"]?.stringValue }
    }

    func testALinkToTheFiftiethOfAThousandMessagesLoadsOneWindowAndTheGapFillsUntilTheSpansMeet() async throws {
        // aprond caps a page at 50 records, allows an account 20 posts and 20 history pages a
        // minute by default, and closes a connection past 60 frames a minute: all lifted here.
        let server = try await Aprond.start([
            "--limit.posts-per-minute", "0", "--limit.posts-per-day", "0", "--limit.ip-posts-per-minute", "0", "--limit.ip-posts-per-day", "0",
            "--limit.server-posts-per-minute", "0", "--limit.server-posts-per-day", "0", "--limit.frames-per-connection-minute", "0",
            "--limit.frames-per-ip-minute", "0", "--limit.server-frames-per-minute", "0", "--limit.history-per-minute", "0",
        ])
        servers.append(server)
        let ada = session(ServerRecord(url: server.url))
        try await waitFor("connected") { ada.status == .signedOut }
        _ = try await ada.signIn(.emailProposal(address: "ada@example.com"))
        _ = try await ada.signIn(.emailCode(try await server.emailCode(for: "ada@example.com")))
        var ids: [LogID] = []
        let posting = ContinuousClock.now
        for index in 1 ... 1000 {
            let id = try await ada.send("#\(index)", in: "general")
            ids.append(try XCTUnwrap(id))
        }
        let posted = ContinuousClock.now - posting
        print("posted 1,000 messages in \(posted)")

        let bob = session(ServerRecord(url: server.url))
        try await waitFor("bob connected") { bob.status == .signedOut }
        _ = try await bob.signIn(.emailProposal(address: "bob@example.com"))
        _ = try await bob.signIn(.emailCode(try await server.emailCode(for: "bob@example.com")))
        try await bob.open("general")
        // Bob's sign-up joined him to general, so the newest 50 records are that join and 49 messages.
        XCTAssertEqual(texts(bob), (952 ... 1000).map { "#\($0)" }, "the newest page: aprond serves at most 50 records")
        let newest = try XCTUnwrap(bob.histories["general"]?.coverage.spans)
        XCTAssertEqual(newest.count, 1)
        let join = try XCTUnwrap(bob.store.membershipLog(of: "general").last?.logID)
        XCTAssertEqual(bob.histories["general"]?.checkpoint, join, "the head is Bob's join")

        let before = requests.sent
        let shown = try await bob.reveal(ids[49], in: "general")
        XCTAssertTrue(shown)
        let sent = requests.sent - before
        XCTAssertEqual(sent, 1, "one window request, not a page back at a time")
        XCTAssertEqual(texts(bob), (50 ... 99).map { "#\($0)" } + (952 ... 1000).map { "#\($0)" }, "the window from #50 and the newest page")
        func logged(_ index: Int) throws -> LogID { try XCTUnwrap(bob.store.message(ids[index])?.logID) }
        let spans = try XCTUnwrap(bob.histories["general"]?.coverage.spans)
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].lower, ids[49], "the window starts at the message asked for")
        XCTAssertEqual(spans[0].upper, try logged(98), "and runs through #99's record")
        XCTAssertEqual(spans[1].upper, join)
        let holes = bob.holes(in: "general")
        XCTAssertEqual(holes, [LogSpan(try logged(98).successor!, spans[1].lower.predecessor!)])
        XCTAssertEqual(bob.timelineItems("general", lineBefore: nil).contains { if case .gap = $0 { true } else { false } }, true)

        // #100 through #951 lie in the hole: 17 pages of 50 and one of two, filled from alternate sides.
        var fills = 0
        var side = Fill.olderFromAbove
        while let hole = bob.holes(in: "general").first {
            try await bob.fill(hole, in: "general", side)
            side = side == .olderFromAbove ? .newerFromBelow : .olderFromAbove
            fills += 1
            if fills > 20 { XCTFail("the hole never closed"); break }
        }
        XCTAssertEqual(fills, 18)
        XCTAssertEqual(texts(bob), (50 ... 1000).map { "#\($0)" })
        XCTAssertEqual(bob.histories["general"]?.coverage.spans.count, 1)
        XCTAssertEqual(bob.histories["general"]?.checkpoint, join)
        XCTAssertTrue(bob.canLoadOlder("general"), "#1 to #49 are still a page back")
    }
}
