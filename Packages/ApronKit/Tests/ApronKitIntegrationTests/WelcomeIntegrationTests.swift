@testable import ApronKit
import Foundation
import XCTest

/// The welcome the Rust server sends before `auth` (Appendix B.1), and the first room's thread
/// listing, against the real server.
@MainActor
final class WelcomeIntegrationTests: XCTestCase {
    private var servers: [Aprond] = []
    private var sessions: [ServerSession] = []

    override func tearDown() async throws {
        for session in sessions { await session.stop() }
        for server in servers { server.stop() }
    }

    private func connected() async throws -> (Aprond, ServerSession) {
        let server = try await Aprond.start()
        servers.append(server)
        let environment = ServerSession.Environment(makeTransport: { WebSocketTransport(url: $0.url, origin: $0.origin) })
        let session = ServerSession(record: ServerRecord(url: server.url), tokens: InMemoryTokenStore(), environment: environment)
        sessions.append(session)
        session.start()
        try await waitFor("connected") { session.status == .signedOut }
        return (server, session)
    }

    private func texts(_ notices: [Notice]) -> [String] { notices.compactMap { $0.body?["text"]?.stringValue } }

    func testTheWelcomeShowsInTheFirstRoomAndASignInByCodeDropsIt() async throws {
        let (server, session) = try await connected()
        try await waitFor("the welcome") { !session.notices.isEmpty }
        XCTAssertEqual(session.notices.map(\.welcome), [true])
        XCTAssertEqual(session.notices.map(\.roomID), [nil])
        XCTAssertTrue(texts(session.notices).first?.hasPrefix("Welcome to Apron Chat. Server version: `") == true, "\(texts(session.notices))")

        try await session.signIn(.guest(name: "Ada"))
        XCTAssertEqual(session.firstRoom, "general")
        XCTAssertEqual(texts(session.notices(in: "general")).count, 1, "a guest the server gives no token still reads it")

        _ = try await session.signIn(.emailProposal(address: "ada@example.com"))
        let code = try await server.emailCode(for: "ada@example.com")
        _ = try await session.signIn(.emailCode(code))
        XCTAssertEqual(session.notices(in: "general"), [], "signed in with a code, the account is past the welcome")
    }

    func testAFirstPageComesWithTheThreadsOthersStarted() async throws {
        let (server, bram) = try await connected()
        try await bram.signIn(.guest(name: "Bram"))
        let created = try await bram.createRoom(title: "Deploy", parentRoomID: "general")
        let thread = try XCTUnwrap(created)

        let environment = ServerSession.Environment(makeTransport: { WebSocketTransport(url: $0.url, origin: $0.origin) })
        let ada = ServerSession(record: ServerRecord(url: server.url), tokens: InMemoryTokenStore(), environment: environment)
        sessions.append(ada)
        ada.start()
        try await waitFor("connected") { ada.status == .signedOut }
        try await ada.signIn(.guest(name: "Ada"))
        XCTAssertNil(ada.store.room(thread), "a thread Ada has not joined is in its own log")
        try await ada.open("general")
        XCTAssertEqual(ada.held, [])
        XCTAssertEqual(ada.timelineItems("general", lineBefore: nil).map(\.id).filter { $0.hasPrefix("thread-") }, ["thread-" + thread],
                       "its card is there as the page is shown")
    }
}
