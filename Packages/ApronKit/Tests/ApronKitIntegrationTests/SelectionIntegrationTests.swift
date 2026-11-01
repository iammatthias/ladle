@testable import ApronKit
import Foundation
import XCTest

/// Select mode against the real Rust server: all or nothing, and a new thread that takes its
/// messages' authors along (apron-web #54, #95).
@MainActor
final class SelectionIntegrationTests: XCTestCase {
    private var servers: [Aprond] = []
    private var sessions: [ServerSession] = []

    override func tearDown() async throws {
        for session in sessions { await session.stop() }
        for server in servers { server.stop() }
    }

    private func connected(_ server: Aprond) async throws -> ServerSession {
        let environment = ServerSession.Environment(makeTransport: { WebSocketTransport(url: $0.url, origin: $0.origin) })
        let session = ServerSession(record: ServerRecord(url: server.url), tokens: InMemoryTokenStore(), environment: environment)
        sessions.append(session)
        session.start()
        try await waitFor("connected") { session.status == .signedOut }
        return session
    }

    private func account(_ server: Aprond, email: String) async throws -> ServerSession {
        let session = try await connected(server)
        _ = try await session.signIn(.emailProposal(address: email))
        _ = try await session.signIn(.emailCode(try await server.emailCode(for: email)))
        return session
    }

    func testANewThreadTakesTheMessagesAndTheirAuthorsOrNothingAtAll() async throws {
        let server = try await Aprond.start()
        servers.append(server)
        let ada = try await account(server, email: "ada@example.com")
        let bob = try await account(server, email: "bob@example.com")
        try await ada.open("general")
        let bobsSent = try await bob.send("Deploy failed at 4pm", in: "general")
        let adasSent = try await ada.send("Rolling back", in: "general")
        let bobsID = try XCTUnwrap(bobsSent), adasID = try XCTUnwrap(adasSent)
        try await waitFor("both loaded") { ada.store.message(bobsID) != nil && ada.store.message(adasID) != nil }

        var mixed = MessageSelection(roomID: "general", first: bobsID)
        _ = mixed.toggle(adasID, order: [])
        let threadsBefore = ada.store.roomIDs.count
        let refused = await ada.moveToNewThread(&mixed, title: "Incident", description: "")
        XCTAssertFalse(refused.moved)
        XCTAssertEqual(refused.problem, "You can only move your own messages, so none were moved")
        XCTAssertNil(refused.roomID, "no thread is made that would stay empty")
        XCTAssertEqual(ada.store.roomIDs.count, threadsBefore)

        let admin = try await connected(server)
        try await admin.signIn(.token(server.adminToken))
        try await admin.open("general")
        try await waitFor("admin loaded") { admin.store.message(bobsID) != nil && admin.store.message(adasID) != nil }
        var picked = MessageSelection(roomID: "general", first: bobsID)
        _ = picked.toggle(adasID, order: [])
        let moved = await admin.moveToNewThread(&picked, title: "Incident", description: "What happened at 4pm")
        XCTAssertTrue(moved.moved, moved.problem ?? "")
        XCTAssertNil(moved.unadded, moved.unadded ?? "")
        let thread = try XCTUnwrap(moved.roomID)
        try await waitFor("moved") { admin.store.message(bobsID)?.roomID == thread && admin.store.message(adasID)?.roomID == thread }
        try await waitFor("Bob is in the thread") { bob.joinedRoomIDs.contains(thread) }
        try await waitFor("Ada is in the thread") { ada.joinedRoomIDs.contains(thread) }
        XCTAssertEqual(admin.store.room(thread)?.parentRoomID, "general")
    }
}
