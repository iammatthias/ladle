@testable import ApronKit
import Foundation
import Synchronization
import XCTest

/// The request layer's waits against the real Rust server: a history page refused for a few
/// seconds is waited out and sent again, so paging back never shows the refusal.
@MainActor
final class LimitsIntegrationTests: XCTestCase {
    private var servers: [Aprond] = []
    private var sessions: [ServerSession] = []
    private final class Sleeps: Sendable {
        let delays = Mutex<[Duration]>([])
    }

    private let sleeps = Sleeps()

    override func tearDown() async throws {
        for session in sessions { await session.stop() }
        for server in servers { server.stop() }
    }

    private func session(_ server: Aprond, pageSize: Int = 50) -> ServerSession {
        let sleeps = sleeps
        let environment = ServerSession.Environment(
            makeTransport: { WebSocketTransport(url: $0.url, origin: $0.origin) },
            sleep: { delay in
                sleeps.delays.withLock { $0.append(delay) }
                try await Task.sleep(for: delay)
            },
            pageSize: pageSize
        )
        let session = ServerSession(record: ServerRecord(url: server.url), tokens: InMemoryTokenStore(), environment: environment)
        sessions.append(session)
        session.start()
        return session
    }

    func testHistoryPagesPastTheMinutesRateWaitOutTheirRefusal() async throws {
        // Fifteen pages a minute, all at once: each page past them waits up to 4 s for the next.
        let server = try await Aprond.start(["--limit.history-per-minute", "15", "--limit.history-burst", "15"])
        servers.append(server)
        let writer = session(server)
        try await waitFor("writer connected") { writer.status == .signedOut }
        try await writer.signIn(.guest(name: nil))
        try await writer.open("general")
        let texts = (1...14).map { "line \($0)" }
        for text in texts { _ = try await writer.send(text, in: "general") }
        try await waitFor("sent") { writer.timeline("general").compactMap { $0.body?["text"]?.stringValue }.suffix(14) == texts }

        let reader = session(server, pageSize: 1)
        try await waitFor("reader connected") { reader.status == .signedOut }
        try await reader.signIn(.guest(name: nil))
        try await reader.open("general")
        while reader.canLoadOlder("general") { try await reader.loadOlder("general") }

        let shown = reader.timeline("general").compactMap { $0.body?["text"]?.stringValue }
        XCTAssertEqual(Array(shown.suffix(14)), texts, "every page came, none refused")
        let waits = sleeps.delays.withLock { $0 }.filter { $0 >= .seconds(1) && $0 <= ShortWait.longest }
        XCTAssertFalse(waits.isEmpty, "a refusal was waited out: \(sleeps.delays.withLock { $0 })")
        XCTAssertNil(reader.wait(.history))
    }
}
