@testable import ApronKit
import Foundation
import XCTest

/// Kept history against the real Rust server: what a session kept comes back on the next launch
/// and catches up from its checkpoint.
@MainActor
final class HistoryIntegrationTests: XCTestCase {
    private var servers: [Aprond] = []
    private var sessions: [ServerSession] = []
    private let tokens = InMemoryTokenStore()
    private let files = InMemoryHistoryFiles()

    override func tearDown() async throws {
        for session in sessions { await session.stop() }
        for server in servers { server.stop() }
    }

    private func session(_ record: ServerRecord, keeping: Bool = true) -> ServerSession {
        let environment = ServerSession.Environment(makeTransport: { WebSocketTransport(url: $0.url, origin: $0.origin) })
        let session = ServerSession(record: record, tokens: tokens,
                                    keeping: keeping ? HistoryKeeping(files: files, settings: HistorySettings()) : nil, environment: environment)
        sessions.append(session)
        session.start()
        return session
    }

    private func texts(_ session: ServerSession) -> [String] {
        session.timeline("general").compactMap { $0.body?["text"]?.stringValue }
    }

    func testARelaunchShowsWhatWasKeptThenCatchesUpOnWhatWasMissed() async throws {
        let server = try await Aprond.start()
        servers.append(server)
        let ada = session(ServerRecord(url: server.url))
        try await waitFor("connected") { ada.status == .signedOut }
        _ = try await ada.signIn(.emailProposal(address: "ada@example.com"))
        _ = try await ada.signIn(.emailCode(try await server.emailCode(for: "ada@example.com")))
        try await ada.open("general")
        for text in ["one", "two", "three"] { _ = try await ada.send(text, in: "general") }
        try await waitFor("sent") { self.texts(ada).suffix(3) == ["one", "two", "three"] }
        let shown = texts(ada)
        await ada.suspend()
        let account = try XCTUnwrap(ada.keptAccount)
        let kept = try XCTUnwrap(files.read(account).flatMap { String(data: $0, encoding: .utf8) })
        let archive = try Archive(text: kept)
        XCTAssertEqual(archive.you?.userID, ada.you?.userID)
        XCTAssertEqual(archive.skipped, 0)

        let bob = session(ServerRecord(url: server.url), keeping: false)
        try await waitFor("bob connected") { bob.status == .signedOut }
        try await bob.signIn(.guest(name: nil))
        _ = try await bob.send("while you were away", in: "general")

        let again = session(ada.record)
        // Catch-up may land before the first look: what was kept leads either way.
        try await waitFor("restored") { self.texts(again).starts(with: shown) }
        try await waitFor("caught up") { self.texts(again) == shown + ["while you were away"] }
        XCTAssertEqual(again.status, .signedIn)
        XCTAssertEqual(again.you?.userID, ada.you?.userID)

        await again.signOut()
        XCTAssertNotNil(files.read(account), "signing out keeps what was kept")
        _ = try await again.signIn(.emailProposal(address: "eve@example.com"))
        _ = try await again.signIn(.emailCode(try await server.emailCode(for: "eve@example.com")))
        try await waitFor("signed in as Eve") { again.status == .signedIn && again.you?.userID != account.userID }
        try await again.open("general")
        await again.flushKept()
        let eve = try XCTUnwrap(again.keptAccount)
        XCTAssertNotNil(files.read(eve))
        await again.signOut(keepingHistory: false)
        XCTAssertNil(files.read(eve), "Keep Local History off deletes Eve's")
        XCTAssertNotNil(files.read(account), "and leaves Ada's")
    }
}
