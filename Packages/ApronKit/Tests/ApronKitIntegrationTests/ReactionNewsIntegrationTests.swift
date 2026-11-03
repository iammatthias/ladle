@testable import ApronKit
import Foundation
import XCTest

/// New reactions to your own messages against the real Rust server: Ada posts, Bob reacts, and
/// Ada's session counts it until she has seen it.
@MainActor
final class ReactionNewsIntegrationTests: XCTestCase {
    private var servers: [Aprond] = []
    private var sessions: [ServerSession] = []

    override func tearDown() async throws {
        for session in sessions { await session.stop() }
        for server in servers { server.stop() }
    }

    private func signedInGuest(_ server: Aprond, _ seen: SeenReactions = SeenReactions()) async throws -> ServerSession {
        let environment = ServerSession.Environment(makeTransport: { WebSocketTransport(url: $0.url, origin: $0.origin) })
        let session = ServerSession(record: ServerRecord(url: server.url), tokens: InMemoryTokenStore(), seenReactions: seen, environment: environment)
        sessions.append(session)
        session.start()
        try await waitFor("connected") { session.status == .signedOut }
        try await session.signIn(.guest(name: nil))
        try await session.open("general")
        return session
    }

    func testAReactionFromSomeoneElseIsNewUntilSeen() async throws {
        let server = try await Aprond.start()
        servers.append(server)
        let ada = try await signedInGuest(server)
        let bob = try await signedInGuest(server)
        let adaKey = ArrangementKey(server: ada.record.id, account: try XCTUnwrap(ada.you?.userID))
        XCTAssertNotNil(ada.seenReactions.baseline(of: "general", adaKey), "first sight at sign-in")

        let sent = try await ada.send("lunch?", in: "general")
        let posted = try XCTUnwrap(sent)
        try await waitFor("Bob has it") { bob.store.message(posted) != nil }
        try await bob.toggleReaction("👍", on: posted)
        try await waitFor("Ada has the reaction") { ada.store.reactions(on: posted) != nil }
        XCTAssertEqual(ada.unseenReactions(in: "general"), [UnseenReactions(messageID: posted, count: 1)])
        XCTAssertEqual(bob.unseenReactions(in: "general"), [], "not Bob's message")

        try await ada.toggleReaction("🎉", on: posted)
        try await waitFor("Ada's own") { ada.store.reactions(on: posted)?.count == 2 }
        XCTAssertEqual(ada.unseenReactionCount(in: "general"), 1, "her own reaction is not news")

        ada.markReactionsSeen([posted])
        XCTAssertEqual(ada.unseenReactionCount(in: "general"), 0)
        XCTAssertNil(ada.nextUnseenReaction(in: "general"))
    }
}
