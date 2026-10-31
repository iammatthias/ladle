@testable import ApronKit
import Foundation
import XCTest

/// What the composer puts on the wire, against the real Rust server: typing (§4.6).
@MainActor
final class ComposerIntegrationTests: XCTestCase {
    private var servers: [Aprond] = []
    private var sessions: [ServerSession] = []

    override func tearDown() async throws {
        for session in sessions { await session.stop() }
        for server in servers { server.stop() }
    }

    private func startServer() async throws -> Aprond {
        let server = try await Aprond.start()
        servers.append(server)
        return server
    }

    private func session(_ server: Aprond) async throws -> ServerSession {
        let environment = ServerSession.Environment(makeTransport: { WebSocketTransport(url: $0.url, origin: $0.origin) })
        let session = ServerSession(record: ServerRecord(url: server.url), tokens: InMemoryTokenStore(), environment: environment)
        sessions.append(session)
        session.start()
        try await waitFor("connected") { session.status == .signedOut }
        return session
    }

    private func account(_ server: Aprond, _ email: String) async throws -> ServerSession {
        let session = try await session(server)
        _ = try await session.signIn(.emailProposal(address: email))
        _ = try await session.signIn(.emailCode(try await server.emailCode(for: email)))
        return session
    }

    func testOneAccountTypingShowsForAnotherUntilItsMessage() async throws {
        let server = try await startServer()
        let ada = try await account(server, "ada@example.com")
        let bob = try await account(server, "bob@example.com")
        try await bob.open("general")
        let adaID = try XCTUnwrap(ada.you?.userID)

        ada.composerChanged(in: "general")
        try await waitFor("bob sees ada typing") { bob.typing["general"]?.map(\.user.userID) == [adaID] }
        XCTAssertEqual(ada.typing, [:], "your own typing never shows, even relayed to your other devices")

        ada.post("hello", in: "general")
        try await waitFor("ada's message ends it") { bob.typing["general"] == nil }
        XCTAssertEqual(bob.timeline("general").last?.plainText, "hello")
    }
}
