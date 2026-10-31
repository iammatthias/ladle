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

    func testARoleMentionListsEveryOtherHolderAndOnlyThoseListedAreMentioned() async throws {
        let server = try await startServer()
        let admin = try await session(server)
        try await admin.signIn(.token(server.adminToken))
        let ada = try await account(server, "ada@example.com")
        let bob = try await account(server, "bob@example.com")
        let carol = try await account(server, "carol@example.com")
        let adaID = try XCTUnwrap(ada.you?.userID), bobID = try XCTUnwrap(bob.you?.userID), carolID = try XCTUnwrap(carol.you?.userID)
        for id in [adaID, bobID, carolID] { try await admin.send("/role \(id) cooks", in: "general") }
        try await carol.open("general")
        try await ada.open("general")
        try await waitFor("carol sees who holds cooks") {
            carol.mentionableRoles(in: "general").first { $0.role == "cooks" }.map { Set($0.members) } == [adaID, bobID]
        }
        let holders = try XCTUnwrap(carol.mentionableRoles(in: "general").first { $0.role == "cooks" }?.members)

        var field = DraftField(text: "@&co")
        guard case .mentions(let found) = carol.suggestions(for: field, in: "general"), case .role(let role) = found.first else {
            return XCTFail("@&co lists the role")
        }
        field.insert(role: role.role)
        field.text += "can someone look"
        try await carol.submit(field, in: "general", attachments: [])

        try await waitFor("ada has it") { ada.timeline("general").last?.plainText == "@&cooks can someone look" }
        let message = try XCTUnwrap(ada.timeline("general").last)
        XCTAssertEqual(message.mentionIDs, holders, "every holder but the sender, in the room's order")
        XCTAssertEqual(ada.mentionCount(in: "general"), 1)
        XCTAssertEqual(carol.mentionCount(in: "general"), 0, "the sender holds the role and is never listed")

        let dan = try await account(server, "dan@example.com")
        let danID = try XCTUnwrap(dan.you?.userID)
        try await admin.send("/role \(danID) cooks", in: "general")
        try await dan.open("general")
        try await waitFor("dan has the message") { dan.timeline("general").last?.messageID == message.messageID }
        XCTAssertEqual(dan.mentionCount(in: "general"), 0, "holding the role later does not make it a mention")
    }
}
