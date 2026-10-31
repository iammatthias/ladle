@testable import ApronKit
import Foundation
import XCTest

/// Rooms and threads against the real Rust server: join, leave and rename lines.
@MainActor
final class RoomsIntegrationTests: XCTestCase {
    private var servers: [Aprond] = []
    private var sessions: [ServerSession] = []

    override func tearDown() async throws {
        for session in sessions { await session.stop() }
        for server in servers { server.stop() }
    }

    private func started() async throws -> Aprond {
        let server = try await Aprond.start()
        servers.append(server)
        return server
    }

    private func connected(_ server: Aprond) async throws -> ServerSession {
        let environment = ServerSession.Environment(makeTransport: { WebSocketTransport(url: $0.url, origin: $0.origin) })
        let session = ServerSession(record: ServerRecord(url: server.url), tokens: InMemoryTokenStore(), environment: environment)
        sessions.append(session)
        session.start()
        try await waitFor("connected") { session.status == .signedOut }
        return session
    }

    private func admin(_ server: Aprond) async throws -> ServerSession {
        let session = try await connected(server)
        try await session.signIn(.token(server.adminToken))
        return session
    }

    private func account(_ server: Aprond, email: String) async throws -> ServerSession {
        let session = try await connected(server)
        _ = try await session.signIn(.emailProposal(address: email))
        _ = try await session.signIn(.emailCode(try await server.emailCode(for: email)))
        return session
    }

    private func lines(_ session: ServerSession, in roomID: String) -> [String] {
        session.timelineItems(roomID, lineBefore: nil).compactMap { item in
            switch item {
            case .members(let line): session.words(line).text
            case .renamed(let rename): MembershipLines.rename(rename.title, thread: false)
            default: nil
            }
        }
    }

    /// apron-web #170: an add is a join, and a rename shows in the room, live and from history.
    func testAddsJoinsLeavesAndRenamesShowAsLinesLiveAndFromHistory() async throws {
        let server = try await started()
        let admin = try await admin(server)
        let ada = try await account(server, email: "ada@example.com")
        let bob = try await account(server, email: "bob@example.com")
        let adminName = try XCTUnwrap(admin.you.map(admin.displayName(for:)))
        let adaName = try XCTUnwrap(ada.you.map(ada.displayName(for:)))

        let created = try await admin.createRoom(title: "Ops")
        let roomID = try XCTUnwrap(created)
        try await admin.open(roomID)
        let adaID = try XCTUnwrap(ada.you?.userID)
        try await admin.addMember(adaID, to: roomID)
        try await waitFor("ada added") { ada.joinedRoomIDs.contains(roomID) }
        _ = try await admin.send("hello", in: roomID)
        _ = try await admin.request("room_set", ["room_id": .string(roomID), "title": "Incidents"])
        try await bob.join(roomID)
        try await waitFor("bob joined") { bob.joinedRoomIDs.contains(roomID) }
        try await bob.leave(roomID)
        try await waitFor("bob left") { !bob.joinedRoomIDs.contains(roomID) }

        try await waitFor("live lines") { self.lines(admin, in: roomID) == ["\(adminName) and \(adaName) joined", "Room renamed to “Incidents”"] }
        XCTAssertEqual(admin.store.membershipLog(of: roomID).last?.entries.map(\.joined), [false], "Bob's join and leave net out")

        let carol = try await connected(server)
        try await carol.signIn(.guest(name: nil))
        try await carol.join(roomID)
        try await carol.open(roomID)
        let carolName = try XCTUnwrap(carol.you.map(carol.displayName(for:)))
        try await waitFor("history lines") { self.lines(carol, in: roomID).count == 3 }
        XCTAssertEqual(lines(carol, in: roomID), ["\(adminName) and \(adaName) joined", "Room renamed to “Incidents”", "\(carolName) joined"],
                       "history replays the add as a join and the rename at their log_ids; Bob nets out of the last run")
        XCTAssertEqual(carol.timelineItems(roomID, lineBefore: nil).compactMap { item -> String? in
            if case .message(let message, _) = item { message.plainText } else { nil }
        }, ["hello"])
    }
}
