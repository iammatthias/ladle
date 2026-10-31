@testable import ApronKit
import Foundation
import XCTest

/// Private rooms and direct messages against the real Rust server: starting one with people,
/// Message finding it again, the "You were added" banner on the other side, a thread taking its
/// room's members, refusals, the private room limit, and adding and removing members.
@MainActor
final class PrivateRoomsIntegrationTests: XCTestCase {
    private var servers: [Aprond] = []
    private var sessions: [ServerSession] = []

    override func tearDown() async throws {
        for session in sessions { await session.stop() }
        for server in servers { server.stop() }
    }

    private func started(_ arguments: [String] = []) async throws -> Aprond {
        let server = try await Aprond.start(arguments)
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

    /// An email account, which private rooms take (a guest may not start or add to one).
    private func account(_ server: Aprond, _ email: String) async throws -> ServerSession {
        let session = try await connected(server)
        _ = try await session.signIn(.emailProposal(address: email))
        _ = try await session.signIn(.emailCode(try await server.emailCode(for: email)))
        try await waitFor("signed in") { session.status == .signedIn && session.you != nil }
        return session
    }

    private func id(_ session: ServerSession) throws -> String { try XCTUnwrap(session.you?.userID) }

    func testADirectMessageStartsOnceAndTheOtherSideSeesTheyWereAdded() async throws {
        let server = try await started()
        let ada = try await account(server, "ada@example.com")
        let bob = try await account(server, "bob@example.com")
        let bobID = try id(bob)
        XCTAssertTrue(ada.mayStartPrivate)
        XCTAssertNil(ada.directRoom(with: bobID))

        let started = try await ada.message(bobID)
        XCTAssertEqual(started.refused, [])
        let roomID = started.roomID
        XCTAssertEqual(ada.store.room(roomID)?.isPrivate, true)
        try await waitFor("Bob listed in Ada's room") { ada.store.members(of: roomID)?.count == 2 }
        XCTAssertEqual(ada.title(of: roomID), ada.users.plainName(for: try XCTUnwrap(bob.you)))
        XCTAssertEqual(ada.privateRoomTree.map(\.roomID), [roomID])
        XCTAssertFalse(ada.wasAdded(to: roomID), "Ada started it")
        XCTAssertEqual(ada.directRoom(with: bobID), roomID)
        let again = try await ada.message(bobID)
        XCTAssertEqual(again, StartedRoom(roomID: roomID, refused: []), "Message opens the conversation they already have")

        try await waitFor("Bob's room arrived") { bob.isPrivateRoom(roomID) }
        XCTAssertTrue(bob.wasAdded(to: roomID))
        XCTAssertEqual(bob.directRoom(with: try id(ada)), roomID)
    }

    func testATruncatedListingKeepsItsMemberCountAndMessageSkipsIt() async throws {
        let server = try await started(["--max-listed-members", "1"])
        let ada = try await account(server, "ada@example.com")
        let bob = try await account(server, "bob@example.com")
        let roomID = try await ada.message(try id(bob)).roomID

        try await waitFor("Bob's room arrived, listed") { bob.isPrivateRoom(roomID) && bob.store.members(of: roomID) != nil }
        XCTAssertEqual(bob.store.members(of: roomID)?.count, 1)
        XCTAssertEqual(bob.store.memberCount(of: roomID), 2)
        XCTAssertEqual(bob.memberTotal(roomID), 2)
        XCTAssertEqual(bob.memberListNote(roomID), "Showing 1 of 2: the most recently active")
        XCTAssertEqual(bob.memberSections(roomID).map(\.title), ["Online"], "the server's statuses section the list")
        XCTAssertNil(bob.directRoom(with: try id(ada)), "a truncated listing says nothing for sure")
    }

    func testAnAddTheServerRefusesIsReportedAndTheRoomIsKept() async throws {
        let server = try await started()
        let ada = try await account(server, "ada@example.com")
        let bob = try await account(server, "bob@example.com")
        let started = try await ada.startPrivateRoom(with: [try id(bob), "nobody"], title: "Plans")
        XCTAssertEqual(started.refused, [Refusal(userID: "nobody", message: "nobody is not a registered user")])
        XCTAssertEqual(ada.title(of: started.roomID), "Plans")
        try await waitFor("Bob added") { bob.isPrivateRoom(started.roomID) }
    }

    func testAGuestMayNotStartAPrivateRoom() async throws {
        let server = try await started()
        let guest = try await connected(server)
        _ = try await guest.signIn(.guest(name: nil))
        XCTAssertFalse(guest.mayStartPrivate)
        do {
            _ = try await guest.startPrivateRoom(with: [])
            XCTFail("a guest started a private room")
        } catch let error as RPCError {
            XCTAssertEqual(error.message, "Sign in to start a private room")
        }
    }

    func testNewRoomWithPrivateCreatesAPrivateRoom() async throws {
        let server = try await started()
        let ada = try await account(server, "ada@example.com")
        let created = try await ada.createRoom(title: "Secret", isPrivate: true)
        let roomID = try XCTUnwrap(created)
        XCTAssertEqual(ada.store.room(roomID)?.isPrivate, true)
        XCTAssertTrue(ada.isPrivateRoom(roomID))
        XCTAssertFalse(ada.publicRoomTree.contains { $0.roomID == roomID })
    }

    func testAThreadOfAPrivateRoomTakesTheRoomsMembers() async throws {
        let server = try await started()
        let ada = try await account(server, "ada@example.com")
        let bob = try await account(server, "bob@example.com")
        let room = try await ada.startPrivateRoom(with: [try id(bob)]).roomID
        try await waitFor("Bob listed") { ada.store.members(of: room)?.count == 2 }
        let created = try await ada.createRoom(title: "Plans", parentRoomID: room)
        let thread = try XCTUnwrap(created)
        XCTAssertEqual(ada.store.room(thread)?.isPrivate, true)
        let note = await ada.includeMembers(of: room, in: thread)
        XCTAssertNil(note)
        try await waitFor("Bob in the thread") { bob.joinedRoomIDs.contains(thread) }
    }

    func testThePrivateRoomLimitIsOfferedAndKept() async throws {
        let server = try await started(["--max-private-rooms", "1"])
        let ada = try await account(server, "ada@example.com")
        XCTAssertEqual(ada.server?.privateRoomLimit, 1)
        XCTAssertFalse(ada.atPrivateRoomLimit)
        _ = try await ada.startPrivateRoom(with: [])
        XCTAssertEqual(ada.privateRoomQuota?.used, 1)
        XCTAssertTrue(ada.atPrivateRoomLimit)
        do {
            _ = try await ada.startPrivateRoom(with: [])
            XCTFail("a second private room past the limit")
        } catch let error as RPCError {
            XCTAssertEqual(error.message, "You are in 1 private rooms, the most at once; leave one to start another")
        }
    }

    func testMembersAreAddedAndRemovedAsTheServerAllows() async throws {
        let server = try await started()
        let ada = try await account(server, "ada@example.com")
        let bob = try await account(server, "bob@example.com")
        let carol = try await account(server, "carol@example.com")
        let room = try await ada.startPrivateRoom(with: [try id(bob)], title: "Crew").roomID
        XCTAssertTrue(ada.mayAddMembers(to: room))

        let refused = await ada.addMembers([try id(carol)], to: room)
        XCTAssertEqual(refused, [])
        try await waitFor("Carol added") { carol.isPrivateRoom(room) }
        try await waitFor("Carol listed") { ada.store.members(of: room)?.count == 3 }

        try await ada.removeMember(try id(carol), from: room)
        try await waitFor("Carol removed") { !carol.joinedRoomIDs.contains(room) }
        try await waitFor("Carol unlisted") { ada.store.members(of: room)?.count == 2 }

        do {
            try await bob.removeMember(try id(ada), from: room)
            XCTFail("Bob removed the room's creator")
        } catch let error as RPCError {
            XCTAssertEqual(error.message, "Only an admin, the room's creator, or a bot's owner, can remove someone else")
        }
    }
}
