@testable import ApronKit
import Foundation
import XCTest

@MainActor
func waitFor(_ message: String, timeout: Duration = .seconds(5), file: StaticString = #filePath, line: UInt = #line,
             _ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            XCTFail("timed out waiting for \(message)", file: file, line: line)
            throw CancellationError()
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// ServerSession against the real Rust server, over URLSession WebSockets.
@MainActor
final class ServerIntegrationTests: XCTestCase {
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

    private func makeSession(_ server: Aprond, origin: String? = nil, tokens: any TokenStore = InMemoryTokenStore(), pageSize: Int = 50) -> ServerSession {
        let record = ServerRecord(url: server.url, origin: origin)
        let environment = ServerSession.Environment(makeTransport: { WebSocketTransport(url: $0.url, origin: $0.origin) }, pageSize: pageSize)
        let session = ServerSession(record: record, tokens: tokens, environment: environment)
        sessions.append(session)
        return session
    }

    private func signedInGuest(_ server: Aprond, pageSize: Int = 50) async throws -> ServerSession {
        let session = makeSession(server, pageSize: pageSize)
        session.start()
        try await waitFor("connected") { session.status == .signedOut }
        try await session.signIn(.guest(name: nil))
        return session
    }

    func testGuestSignInListsTheDefaultRoom() async throws {
        let server = try await startServer()
        let session = makeSession(server)
        session.start()
        try await waitFor("connected") { session.status == .signedOut }
        XCTAssertEqual(session.server?.apron, 9)
        XCTAssertEqual(session.server.map { Set($0.auth) }, ["webauthn", "email", "token", "guest"])

        let outcome = try await session.signIn(.guest(name: "Ada"))
        guard case .signedIn(let you) = outcome else { return XCTFail("expected a sign-in, got \(outcome)") }
        XCTAssertTrue(you.userID.hasPrefix("guest_"), you.userID)
        XCTAssertEqual(session.status, .signedIn)
        XCTAssertEqual(session.joinedRoomIDs, ["general"])
        XCTAssertEqual(session.roomTree, [RoomNode(roomID: "general", threadIDs: [])])
        XCTAssertEqual(session.title(of: "general"), "General")
        XCTAssertEqual(session.store.members(of: "general")?.map(\.userID), [you.userID])
    }

    func testEmailSignInThenAReconnectResumesWithTheBearerTokenAsTheSameUser() async throws {
        let server = try await startServer()
        let tokens = InMemoryTokenStore()
        let session = makeSession(server, tokens: tokens)
        session.start()
        try await waitFor("connected") { session.status == .signedOut }

        let proposed = try await session.signIn(.emailProposal(address: "ada@example.com"))
        XCTAssertEqual(proposed, .codeSent(to: "ada@example.com"))
        let code = try await server.emailCode(for: "ada@example.com")
        XCTAssertEqual(code.count, 6)
        let approved = try await session.signIn(.emailCode(code))
        guard case .signedIn(let you) = approved else { return XCTFail("expected a sign-in, got \(approved)") }
        let token = try XCTUnwrap(try tokens.token(for: session.record.id))
        XCTAssertNotEqual(token, code, "the bearer token is not the mailed code")
        XCTAssertEqual(session.record.account?.scheme, "email")

        await session.stop()
        XCTAssertEqual(session.status, .offline)
        session.start()
        try await waitFor("resumed") { session.status == .signedIn }
        XCTAssertEqual(session.you?.userID, you.userID)
        XCTAssertEqual(session.joinedRoomIDs, ["general"])
    }

    func testSendReplyEditReactAndDeleteLandInTheReplayStore() async throws {
        let server = try await startServer()
        let session = try await signedInGuest(server)
        try await session.open("general")
        let me = try XCTUnwrap(session.you?.userID)

        let firstResult = try await session.send("hello", in: "general")
        let first = try XCTUnwrap(firstResult)
        try await waitFor("message installed") { session.store.message(first) != nil }
        XCTAssertEqual(session.store.message(first)?.body?["text"], "hello")
        XCTAssertEqual(session.store.message(first)?.logID, first)

        let replyResult = try await session.send("a reply", in: "general", replyTo: first)
        let reply = try XCTUnwrap(replyResult)
        try await waitFor("reply installed") { session.store.message(reply) != nil }
        XCTAssertEqual(session.store.message(reply)?.replyTo, first)

        try await session.edit(try XCTUnwrap(session.store.message(first)), text: "hello world")
        try await waitFor("edit installed") { session.store.message(first)?.body?["text"] == "hello world" }
        let edited = try XCTUnwrap(session.store.message(first))
        XCTAssertGreaterThan(edited.logID, first)

        try await session.toggleReaction("👍", on: first)
        try await waitFor("reaction installed") { session.store.reactions(on: first) != nil }
        XCTAssertEqual(session.store.reactions(on: first), [ReplayStore.ReactionSummary(emoji: "👍", userIDs: [me])])
        try await session.toggleReaction("🎉", on: first)
        try await waitFor("second reaction") { session.store.reactions(on: first)?.count == 2 }
        try await session.toggleReaction("👍", on: first)
        try await waitFor("reaction removed") { session.store.reactions(on: first)?.map(\.emoji) == ["🎉"] }

        try await session.delete(edited)
        try await waitFor("tombstone installed") { session.store.message(first)?.isTombstone == true }
        XCTAssertNil(session.store.message(first)?.body)
        XCTAssertNil(session.store.reactions(on: first), "a tombstone hides its reactions")
        XCTAssertEqual(session.timeline("general").map(\.messageID), [reply], "the deleted message leaves the timeline")
    }

    func testHistoryPagesBackPastOnePage() async throws {
        let server = try await startServer()
        let writer = try await signedInGuest(server)
        var sent: [LogID] = []
        for index in 1 ... 7 {
            let posted = try await writer.send("message \(index)", in: "general")
            sent.append(try XCTUnwrap(posted))
        }

        let reader = try await signedInGuest(server, pageSize: 3)
        try await reader.open("general")
        let firstPage = reader.timeline("general").count
        XCTAssertLessThanOrEqual(firstPage, 3)
        XCTAssertEqual(reader.canLoadOlder("general"), true)
        var pages = 1
        while reader.canLoadOlder("general") {
            try await reader.loadOlder("general")
            pages += 1
            XCTAssertLessThan(pages, 20, "paging terminates")
        }
        XCTAssertGreaterThanOrEqual(pages, 3)
        XCTAssertEqual(reader.timeline("general").map(\.messageID), sent)
        XCTAssertEqual(reader.timeline("general").map { $0.body?["text"]?.stringValue }, (1 ... 7).map { "message \($0)" })
    }

    func testAThreadIsARoomWithAParent() async throws {
        let server = try await startServer()
        let session = try await signedInGuest(server)
        let threadResult = try await session.createRoom(title: "Deploy", parentRoomID: "general")
        let thread = try XCTUnwrap(threadResult)
        try await waitFor("thread listed") { session.roomTree.first?.threadIDs == [thread] }
        XCTAssertEqual(session.store.room(thread)?.parentRoomID, "general")
        XCTAssertEqual(session.title(of: thread), "Deploy")
        XCTAssertTrue(session.joinedRoomIDs.contains(thread))

        let postedResult = try await session.send("in the thread", in: thread)
        let posted = try XCTUnwrap(postedResult)
        try await waitFor("thread message") { session.timeline(thread).map(\.messageID) == [posted] }
        XCTAssertEqual(session.timeline("general"), [])

        try await session.leave(thread)
        try await waitFor("left thread") { !session.joinedRoomIDs.contains(thread) }
        try await session.join(thread)
        try await waitFor("rejoined thread") { session.joinedRoomIDs.contains(thread) }
    }

    func testTwoServersAtOnceKeepSeparateIdentitiesAndRooms() async throws {
        let one = try await startServer()
        let two = try await startServer()
        let tokens = InMemoryTokenStore()
        let store = SessionStore(serverStore: nil, tokens: tokens)
        let first = store.add(ServerRecord(url: one.url))
        let second = store.add(ServerRecord(url: two.url))
        sessions += [first, second]
        try await waitFor("both connected") { first.status == .signedOut && second.status == .signedOut }

        _ = try await first.signIn(.emailProposal(address: "ada@example.com"))
        _ = try await first.signIn(.emailCode(try await one.emailCode(for: "ada@example.com")))
        try await second.signIn(.guest(name: "Bob"))
        XCTAssertNotNil(try tokens.token(for: first.record.id))
        XCTAssertNil(try tokens.token(for: second.record.id), "this server issues guests no token")
        XCTAssertEqual(store.records.map(\.account?.scheme), ["email", "guest"])

        let onOneResult = try await first.send("on one", in: "general")
        let onOne = try XCTUnwrap(onOneResult)
        let onTwoResult = try await second.send("on two", in: "general")
        let onTwo = try XCTUnwrap(onTwoResult)
        try await waitFor("both delivered") { first.store.message(onOne) != nil && second.store.message(onTwo) != nil }
        XCTAssertEqual(first.timeline("general").compactMap { $0.body?["text"]?.stringValue }, ["on one"])
        XCTAssertEqual(second.timeline("general").compactMap { $0.body?["text"]?.stringValue }, ["on two"])
        XCTAssertTrue(second.you?.userID.hasPrefix("guest_") == true)
        XCTAssertFalse(first.you?.userID.hasPrefix("guest_") ?? true)
    }

    /// aprond lets an upgrade without `Origin` through, so a 403 here proves URLSession sent the
    /// header; the default origin of the same server connecting shows the check is the cause.
    /// Fixing the record's origin reconnects a session that the server refused.
    func testTheServerSeesTheOriginHeader() async throws {
        let server = try await startServer()
        let foreign = makeSession(server, origin: "https://evil.example")
        foreign.start()
        try await waitFor("rejected") { foreign.status == .stopped(.rejected(status: 403)) }
        XCTAssertNil(foreign.server)

        var fixed = foreign.record
        fixed.origin = ServerRecord.defaultOrigin(for: server.url)
        await foreign.update(fixed)
        try await waitFor("reconnected after the origin was fixed") { foreign.status == .signedOut }

        let local = makeSession(server)
        XCTAssertEqual(local.record.origin, "https://127.0.0.1:\(server.port)")
        local.start()
        try await waitFor("accepted") { local.status == .signedOut }
    }
}
