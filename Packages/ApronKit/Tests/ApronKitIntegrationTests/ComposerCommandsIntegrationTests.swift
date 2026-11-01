@testable import ApronKit
import Foundation
import XCTest

/// The composer's local commands against the real Rust server: `/nick`, `/join`, `/leave`,
/// `/topic`, `/kick` and `/invite` as the requests they spell, and a refused one's notice.
@MainActor
final class ComposerCommandsIntegrationTests: XCTestCase {
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

    private func account(_ server: Aprond, _ email: String) async throws -> ServerSession {
        let session = try await connected(server)
        _ = try await session.signIn(.emailProposal(address: email))
        _ = try await session.signIn(.emailCode(try await server.emailCode(for: email)))
        return session
    }

    @discardableResult
    private func run(_ text: String, as session: ServerSession, in roomID: String) async throws -> String? {
        try await session.submit(ComposerDraft(field: DraftField(text: text)), in: roomID)
    }

    func testEachLocalCommandChangesWhatItSpells() async throws {
        let server = try await Aprond.start()
        servers.append(server)
        let admin = try await connected(server)
        try await admin.signIn(.token(server.adminToken))
        let ada = try await account(server, "ada@example.com")
        let adaID = try XCTUnwrap(ada.you?.userID)
        let created = try await admin.createRoom(title: "Ops")
        let roomID = try XCTUnwrap(created)

        try await run("/invite @\(adaID)", as: admin, in: roomID)
        try await waitFor("ada added") { ada.joinedRoomIDs.contains(roomID) }

        try await run("/topic Deploys *only*", as: admin, in: roomID)
        try await waitFor("topic set") { ada.roomDescription(roomID) == "Deploys *only*" }
        XCTAssertEqual(ada.title(of: roomID), "Ops", "the title goes with it, so it stays")

        try await run("/kick \(adaID)", as: admin, in: roomID)
        try await waitFor("ada removed") { !ada.joinedRoomIDs.contains(roomID) }

        let shown = try await run("/join Ops", as: ada, in: "general")
        XCTAssertEqual(shown, roomID, "found by the title of the record ada still holds")
        try await waitFor("ada joined") { ada.joinedRoomIDs.contains(roomID) }

        try await run("/leave #\(roomID)", as: ada, in: "general")
        try await waitFor("ada left") { !ada.joinedRoomIDs.contains(roomID) }

        try await run("/nick Ada L", as: ada, in: "general")
        try await waitFor("renamed") { ada.you?.json["name"]?.stringValue == "Ada L" }
        try await admin.open("general")
        try await waitFor("others see it") { admin.users.user(adaID)?["name"]?.stringValue == "Ada L" }
    }

    func testARefusedCommandLeavesTheServersReasonAndGivesTheDraftBack() async throws {
        let server = try await Aprond.start()
        servers.append(server)
        let ada = try await account(server, "ada@example.com")
        let bob = try await account(server, "bob@example.com")
        let bobID = try XCTUnwrap(bob.you?.userID)
        try await ada.open("general")

        let draft = ComposerDraft(field: DraftField(text: "/kick @\(bobID)"))
        do {
            try await ada.submit(draft, in: "general")
            XCTFail("ada removed bob from general")
        } catch let failure as CommandFailure {
            XCTAssertEqual(failure.draft, draft)
            XCTAssertEqual(ada.notices.last?.roomID, "general")
            XCTAssertEqual(ada.notices.last?.from.userID, "~private")
            XCTAssertEqual(ada.notices.last?.body?["text"]?.stringValue, failure.reason)
            XCTAssertEqual(failure.reason, "Only an admin, the room's creator, or a bot's owner, can remove someone else")
        }
        XCTAssertTrue(bob.joinedRoomIDs.contains("general"))
    }
}
