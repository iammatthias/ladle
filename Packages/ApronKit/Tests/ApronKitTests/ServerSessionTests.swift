import Foundation
import Synchronization
import XCTest
@testable import ApronKit

/// A clock whose sleeps record their delay and wait until the test releases them.
final class FakeClock: Sendable {
    let delays = Mutex<[Duration]>([])
    private let released = Mutex(0)

    func sleep(_ delay: Duration) async throws {
        let index = delays.withLock { $0.append(delay); return $0.count }
        while released.withLock({ $0 }) < index {
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    func release() { released.withLock { $0 += 1 } }
    var recorded: [Duration] { delays.withLock { $0 } }
}

/// Polls an async condition until it holds or two seconds pass.
@MainActor
func eventually(_ message: String = "condition", file: StaticString = #filePath, line: UInt = #line, _ condition: @MainActor () async -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(2)
    while !(await condition()) {
        if ContinuousClock.now > deadline {
            XCTFail("timed out waiting for \(message)", file: file, line: line)
            return
        }
        try? await Task.sleep(for: .milliseconds(1))
    }
}

/// The transports a session connects with, in order. With none queued, a fresh one that greets.
final class Transports: Sendable {
    let queued = Mutex<[FakeTransport]>([])
    let made = Mutex<[FakeTransport]>([])

    func next() -> FakeTransport {
        let transport = queued.withLock { $0.isEmpty ? nil : $0.removeFirst() } ?? {
            let fresh = FakeTransport()
            Task { await fresh.deliver(ServerSessionTests.greeting) }
            return fresh
        }()
        made.withLock { $0.append(transport) }
        return transport
    }
}

@MainActor
final class ServerSessionTests: XCTestCase {
    static let greeting: JSONValue = ["method": "server", "params": [
        "apron": 9, "auth": ["email", "token", "guest"], "capabilities": ["history", "edit", "rooms", "reactions"],
    ]]
    let record = ServerRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, url: URL(string: "wss://chat.example/ws")!)
    let tokens = InMemoryTokenStore()
    let clock = FakeClock()
    let transports = Transports()
    var session: ServerSession!

    override func setUp() async throws {
        let counter = Mutex(0)
        let transports = transports, clock = clock
        let environment = ServerSession.Environment(
            makeTransport: { _ in transports.next() },
            sleep: { try await clock.sleep($0) },
            jitter: { 1 },
            makeRequestID: { counter.withLock { $0 += 1; return "c\($0)" } },
            makeState: { "state-1" },
            agent: "ladle-ios/test",
            pageSize: 3
        )
        session = ServerSession(record: record, tokens: tokens, environment: environment)
    }

    override func tearDown() async throws {
        await session.stop()
    }

    private func transport(_ index: Int) async -> FakeTransport {
        await eventually("transport \(index)") { transports.made.withLock { $0.count > index } }
        return transports.made.withLock { $0[index] }
    }

    private func frames(_ transport: FakeTransport, count: Int) async -> [String] {
        await eventually("\(count) frames") { await transport.sentLog.count >= count }
        return await Array(transport.sentLog.prefix(count))
    }

    private func frame(_ transport: FakeTransport, _ index: Int) async -> String {
        await frames(transport, count: index + 1).last ?? ""
    }

    private func signInAsGuest(on transport: FakeTransport) async throws {
        await eventually("signed out") { session.status == .signedOut }
        let signIn = Task { try await session.signIn(.guest(name: nil)) }
        _ = await frames(transport, count: 2)
        await transport.deliver(["id": "c1", "result": ["you": ["user_id": "ada", "name": "Ada"], "token": "t1"]])
        await transport.deliver(["id": "c2", "result": ["joined": [["room_id": "general", "log_id": "100", "title": "General", "latest_log_id": "100", "history_log_id": "100"]]]])
        _ = try await signIn.value
    }

    // MARK: Sign-in

    func testResumePipelinesRoomListBehindTheTokenAndSavesTheRotatedOne() async throws {
        try tokens.setToken("t1", for: record.id)
        var changes: [ServerRecord.Account?] = []
        session.onRecordChange = { changes.append($0.account) }
        session.start()
        let socket = await transport(0)
        let sent = await frames(socket, count: 2)
        XCTAssertEqual(sent, [
            #"{"id":"c1","method":"auth","params":{"agent":"ladle-ios/test","scheme":"token","token":"t1"}}"#,
            #"{"id":"c2","method":"room_list","params":{"filter":"joined","members":true}}"#,
        ])
        await socket.deliver(["id": "c1", "result": ["you": ["user_id": "ada", "name": "Ada"], "token": "t2"]])
        await socket.deliver(["id": "c2", "result": [
            "joined": [
                ["room_id": "general", "log_id": "100", "title": "General", "latest_log_id": "120", "history_log_id": "100",
                 "members": [["user_id": "ada"], ["user_id": "bob"]]],
                ["room_id": "130", "log_id": "130", "parent_room_id": "general", "title": "Deploy", "latest_log_id": "130", "history_log_id": "130"],
            ],
            "users": [["user_id": "ada", "name": "Ada"], ["user_id": "bob", "name": "Bob"]],
        ]])
        await eventually("room list applied") { session.joinedRoomIDs.count == 2 }
        XCTAssertEqual(session.status, .signedIn)
        XCTAssertEqual(session.you?.userID, "ada")
        XCTAssertEqual(try tokens.token(for: record.id), "t2")
        XCTAssertEqual(changes, [ServerRecord.Account(userID: "ada", name: "Ada", scheme: "token")])
        XCTAssertEqual(session.roomTree, [RoomNode(roomID: "general", threadIDs: ["130"])])
        XCTAssertEqual(session.store.members(of: "general")?.map(\.userID), ["ada", "bob"])
        XCTAssertEqual(session.displayName(for: UserObject(["user_id": "bob"])!), "Bob")
    }

    func testGuestSignInWithoutATokenLeavesNoneSaved() async throws {
        session.start()
        let socket = await transport(0)
        await eventually("signed out") { session.status == .signedOut }
        let signIn = Task { try await session.signIn(.guest(name: "Ada")) }
        let sent = await frames(socket, count: 2)
        XCTAssertEqual(sent, [
            #"{"id":"c1","method":"auth","params":{"agent":"ladle-ios/test","name":"Ada","scheme":"guest"}}"#,
            #"{"id":"c2","method":"room_list","params":{"filter":"joined","members":true}}"#,
        ])
        await socket.deliver(["id": "c1", "result": ["you": ["user_id": "guest_1", "name": "Ada"]]])
        await socket.deliver(["id": "c2", "result": ["joined": []]])
        let outcome = try await signIn.value
        XCTAssertEqual(outcome, .signedIn(UserObject(["user_id": "guest_1", "name": "Ada"])!))
        XCTAssertNil(try tokens.token(for: record.id))
        XCTAssertEqual(session.record.account, ServerRecord.Account(userID: "guest_1", name: "Ada", scheme: "guest"))
    }

    func testEmailProposalThenCodeOnTheSameConnection() async throws {
        session.start()
        let socket = await transport(0)
        await eventually("signed out") { session.status == .signedOut }
        let propose = Task { try await session.signIn(.emailProposal(address: "ada@example.com")) }
        let proposal = await frame(socket, 0)
        XCTAssertEqual(proposal, #"{"id":"c1","method":"auth","params":{"agent":"ladle-ios/test","email":"ada@example.com","scheme":"email","state":"state-1"}}"#)
        await socket.deliver(["id": "c1", "result": [:]])
        let proposed = try await propose.value
        XCTAssertEqual(proposed, .codeSent(to: "ada@example.com"))
        XCTAssertEqual(session.pendingEmail, "ada@example.com")
        XCTAssertEqual(session.status, .signedOut)

        let approve = Task { try await session.signIn(.emailCode("418092")) }
        let sent = await frames(socket, count: 3)
        XCTAssertEqual(Array(sent[1...]), [
            #"{"id":"c2","method":"auth","params":{"agent":"ladle-ios/test","scheme":"email","token":"418092"}}"#,
            #"{"id":"c3","method":"room_list","params":{"filter":"joined","members":true}}"#,
        ])
        await socket.deliver(["id": "c2", "result": ["you": ["user_id": "ada"], "token": "st_1"]])
        await socket.deliver(["id": "c3", "result": ["joined": []]])
        _ = try await approve.value
        XCTAssertEqual(try tokens.token(for: record.id), "st_1")
        XCTAssertNil(session.pendingEmail)
        XCTAssertEqual(session.status, .signedIn)
    }

    func testAWrongCodeKeepsTheProposalOpen() async throws {
        session.start()
        let socket = await transport(0)
        await eventually("signed out") { session.status == .signedOut }
        let propose = Task { try await session.signIn(.emailProposal(address: "ada@example.com")) }
        _ = await frame(socket, 0)
        await socket.deliver(["id": "c1", "result": [:]])
        _ = try await propose.value
        let approve = Task { try await session.signIn(.emailCode("000000")) }
        _ = await frames(socket, count: 3)
        await socket.deliver(["id": "c2", "error": ["code": -32001, "message": "Wrong code"]])
        do {
            _ = try await approve.value
            XCTFail("expected denied")
        } catch let error as RPCError {
            XCTAssertEqual(error, RPCError(code: -32001, message: "Wrong code"))
        }
        XCTAssertEqual(session.pendingEmail, "ada@example.com")
        XCTAssertEqual(session.status, .signedOut)
    }

    func testADeniedResumeClearsTheTokenAndAsksForSignIn() async throws {
        try tokens.setToken("expired", for: record.id)
        session.start()
        let socket = await transport(0)
        _ = await frames(socket, count: 2)
        await socket.deliver(["id": "c1", "error": ["code": -32001, "message": "Session expired; sign in again"]])
        await eventually("signed out") { session.status == .signedOut }
        XCTAssertNil(try tokens.token(for: record.id))
        XCTAssertEqual(session.signInNeeded, "Session expired; sign in again")
        XCTAssertNil(session.you)
    }

    // MARK: Disconnects

    func testADropFailsPendingRequestsAndReconnectsWithBackoffThenResumes() async throws {
        let failing = [FakeTransport(), FakeTransport(dropped: true), FakeTransport(dropped: true)]
        await failing[0].deliver(Self.greeting)
        transports.queued.withLock { $0 = failing }
        session.start()
        let first = await transport(0)
        try await signInAsGuest(on: first)

        let posting = Task { try await session.send("hello", in: "general") }
        let post = await frame(first, 2)
        XCTAssertEqual(post, #"{"id":"c3","method":"message","params":{"body":{"format":"plain","text":"hello"},"room_id":"general"}}"#)
        await first.dropFromServer()
        do {
            _ = try await posting.value
            XCTFail("a pending request fails when the connection drops")
        } catch let error as Connection.Failure {
            XCTAssertEqual(error, .closed)
        }

        await eventually("first backoff") { clock.recorded.count == 1 }
        XCTAssertEqual(session.status, .reconnecting(attempt: 1, delay: .milliseconds(500)))
        clock.release()
        await eventually("second backoff") { clock.recorded.count == 2 }
        clock.release()
        await eventually("third backoff") { clock.recorded.count == 3 }
        XCTAssertEqual(clock.recorded, [.milliseconds(500), .seconds(1), .seconds(2)])
        clock.release()

        let fourth = await transport(3)
        let resumed = await frames(fourth, count: 2)
        XCTAssertEqual(resumed, [
            #"{"id":"c4","method":"auth","params":{"agent":"ladle-ios/test","scheme":"token","token":"t1"}}"#,
            #"{"id":"c5","method":"room_list","params":{"filter":"joined","members":true}}"#,
        ])
        await fourth.deliver(["id": "c4", "result": ["you": ["user_id": "ada", "name": "Ada"]]])
        await eventually("signed in again") { session.status == .signedIn }
        XCTAssertEqual(try tokens.token(for: record.id), "t1")
    }

    func testBackoffDoublesToASixtySecondCap() {
        let delays = (1 ... 9).map { ServerSession.backoff(attempt: $0, jitter: 1) }
        XCTAssertEqual(delays, [.milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(32), .seconds(60), .seconds(60)])
        XCTAssertEqual(ServerSession.backoff(attempt: 2, jitter: 0.8), .milliseconds(800))
    }

    func testAConnectionLevelDenialStopsReconnecting() async throws {
        session.start()
        let socket = await transport(0)
        await eventually("signed out") { session.status == .signedOut }
        await socket.deliver(["error": ["code": -32001, "message": "Banned"]])
        await socket.dropFromServer()
        await eventually("stopped") { session.status == .stopped(.denied("Banned")) }
        XCTAssertEqual(clock.recorded, [])
    }

    func testRetryAfterIsTheShortestReconnectDelay() async throws {
        session.start()
        let socket = await transport(0)
        await eventually("signed out") { session.status == .signedOut }
        await socket.deliver(["error": ["code": -32002, "message": "Server at capacity", "data": ["retry_after": 30]]])
        await socket.dropFromServer()
        await eventually("backoff") { clock.recorded.count == 1 }
        XCTAssertEqual(clock.recorded, [.seconds(30)])
    }

    // MARK: History

    private func message(_ id: String, _ text: String, room: String = "general") -> JSONValue {
        ["message_id": .string(id), "log_id": .string(id), "room_id": .string(room), "from": ["user_id": "bob"], "body": ["text": .string(text)]]
    }

    func testPagesNewestFirstThenOlderUntilTheStart() async throws {
        session.start()
        let socket = await transport(0)
        try await signInAsGuest(on: socket)

        let open = Task { try await session.open("general") }
        let newest = await frame(socket, 2)
        XCTAssertEqual(newest, #"{"id":"c3","method":"history","params":{"limit":3,"room_id":"general"}}"#)
        await socket.deliver(["id": "c3", "result": [
            "messages": [message("104", "d"), message("105", "e"), message("106", "f")],
            "first_log_id": "104", "last_log_id": "106", "more": true, "latest_log_id": "106", "history_log_id": "101",
        ]])
        try await open.value
        XCTAssertEqual(session.histories["general"]?.canLoadOlder, true)

        let older = Task { try await session.loadOlder("general") }
        let olderFrame = await frame(socket, 3)
        XCTAssertEqual(olderFrame, #"{"id":"c4","method":"history","params":{"before":"103","limit":3,"room_id":"general"}}"#)
        await socket.deliver(["id": "c4", "result": [
            "messages": [message("101", "a"), message("102", "b"), message("103", "c")],
            "first_log_id": "101", "last_log_id": "103", "more": false, "latest_log_id": "106", "history_log_id": "101",
        ]])
        try await older.value
        XCTAssertEqual(session.histories["general"]?.canLoadOlder, false)
        try await session.loadOlder("general")
        let sentCount = await socket.sentLog.count
        XCTAssertEqual(sentCount, 4, "no request past the start")
        XCTAssertEqual(session.timeline("general").map(\.messageID.text), ["101", "102", "103", "104", "105", "106"])
    }

    func testAReconnectCatchesUpOpenedRoomsFromTheirCheckpoint() async throws {
        let firstSocket = FakeTransport()
        await firstSocket.deliver(Self.greeting)
        transports.queued.withLock { $0 = [firstSocket] }
        session.start()
        try await signInAsGuest(on: firstSocket)
        let open = Task { try await session.open("general") }
        _ = await frame(firstSocket, 2)
        await firstSocket.deliver(["id": "c3", "result": [
            "messages": [message("104", "d")], "first_log_id": "104", "last_log_id": "104", "more": false,
            "latest_log_id": "104", "history_log_id": "101",
        ]])
        try await open.value
        await firstSocket.deliver(["method": "message", "params": message("107", "live")])
        await eventually("live message") { session.timeline("general").count == 2 }
        await firstSocket.dropFromServer()
        await eventually("backoff") { clock.recorded.count == 1 }
        clock.release()

        let second = await transport(1)
        _ = await frames(second, count: 2)
        await second.deliver(["id": "c4", "result": ["you": ["user_id": "ada", "name": "Ada"]]])
        await second.deliver(["id": "c5", "result": ["joined": [["room_id": "general", "log_id": "100", "latest_log_id": "109", "history_log_id": "101"]]]])
        let catchUp = await frame(second, 2)
        XCTAssertEqual(catchUp, #"{"id":"c6","method":"history","params":{"after":"108","limit":200,"room_id":"general"}}"#)
        await second.deliver(["id": "c6", "result": [
            "messages": [message("109", "missed")], "first_log_id": "109", "last_log_id": "109", "more": false,
            "latest_log_id": "109", "history_log_id": "101",
        ]])
        await eventually("caught up") { session.timeline("general").count == 3 }
        XCTAssertEqual(session.timeline("general").map(\.messageID.text), ["104", "107", "109"])
    }

    func testOwnReadCursorOnlyMovesForwardAndOthersAreIgnored() async throws {
        session.start()
        let socket = await transport(0)
        try await signInAsGuest(on: socket)
        func activity(_ from: String, _ read: String) -> JSONValue {
            ["method": "activity", "params": ["room_id": "general", "from": ["user_id": .string(from)], "read_message_id": .string(read)]]
        }
        await socket.deliver(activity("ada", "200"))
        await socket.deliver(activity("bob", "300"))
        await socket.deliver(activity("ada", "150"))
        await socket.deliver(["method": "message", "params": message("199", "x")])
        await eventually("frames applied") { session.timeline("general").count == 1 }
        XCTAssertEqual(session.readCursors, ["general": LogID("200")!])
    }

    // MARK: Operations

    func testOperationsSendTheirFramesAndResendClientFieldsOnEdit() async throws {
        session.start()
        let socket = await transport(0)
        try await signInAsGuest(on: socket)
        await socket.deliver(["method": "message", "params": [
            "message_id": "200", "log_id": "200", "room_id": "general", "from": ["user_id": "ada"],
            "body": ["text": "helo", "format": "markdown", "mentions": ["bob"]], "reply_to": ["message_id": "150"],
        ]])
        await eventually("message installed") { session.store.message(LogID("200")!) != nil }
        let original = try XCTUnwrap(session.store.message(LogID("200")!))

        var index = 2
        func expect(_ expected: String, reply: JSONValue = [:], _ operation: @escaping @MainActor () async throws -> Void) async throws {
            let running = Task { try await operation() }
            let sent = await frame(socket, index)
            XCTAssertEqual(sent, expected)
            await socket.deliver(["id": .string("c\(index + 1)"), "result": reply])
            try await running.value
            index += 1
        }

        try await expect(#"{"id":"c3","method":"message","params":{"body":{"format":"plain","text":"hi"},"reply_to":{"message_id":"200"},"room_id":"general"}}"#,
                         reply: ["message_id": "201"]) { try await self.session.send("hi", in: "general", replyTo: LogID("200")) }
        try await expect(#"{"id":"c4","method":"message","params":{"body":{"format":"markdown","mentions":["bob"],"text":"hello"},"message_id":"200","reply_to":{"message_id":"150"},"room_id":"general"}}"#) {
            try await self.session.edit(original, text: "hello")
        }
        try await expect(#"{"id":"c5","method":"message","params":{"deleted":true,"message_id":"200","room_id":"general"}}"#) {
            try await self.session.delete(original)
        }
        try await expect(#"{"id":"c6","method":"reactions","params":{"emojis":["👍"],"message_id":"201"}}"#) {
            try await self.session.toggleReaction("👍", on: LogID("201")!)
        }
        await socket.deliver(["method": "message", "params": message("201", "hi")])
        await socket.deliver(["method": "reactions", "params": [
            "log_id": "202", "message_id": "201", "room_id": "general", "reactions": [["from": ["user_id": "ada"], "emojis": ["👍", "🎉"]]],
        ]])
        await eventually("reaction installed") { session.store.reactions(on: LogID("201")!)?.count == 2 }
        try await expect(#"{"id":"c7","method":"reactions","params":{"emojis":["🎉"],"message_id":"201"}}"#) {
            try await self.session.toggleReaction("👍", on: LogID("201")!)
        }
        try await expect(#"{"id":"c8","method":"room_join","params":{"room_id":"ops"}}"#) { try await self.session.join("ops") }
        try await expect(#"{"id":"c9","method":"room_leave","params":{"room_id":"ops"}}"#) { try await self.session.leave("ops") }
        try await expect(#"{"id":"c10","method":"room_set","params":{"parent_room_id":"general","title":"Deploy"}}"#,
                         reply: ["room_id": "300"]) { try await self.session.createRoom(title: "Deploy", parentRoomID: "general") }
    }

    func testOperationsNeedASignedInConnection() async throws {
        do {
            try await session.send("hi", in: "general")
            XCTFail("expected notConnected")
        } catch let error as ServerSession.Failure {
            XCTAssertEqual(error, .notConnected)
        }
    }
}

final class SignInValueTests: XCTestCase {
    func testTokenPayloadAcceptsABareTokenOrALink() {
        XCTAssertEqual(TokenPayload(parsing: "  st_abc123\n"), TokenPayload(token: "st_abc123"))
        XCTAssertEqual(TokenPayload(parsing: "https://link.apron.chat/#server=wss://chat.example/ws&token=inv_Qm7x"),
                       TokenPayload(token: "inv_Qm7x", server: URL(string: "wss://chat.example/ws")))
        XCTAssertEqual(TokenPayload(parsing: "apron:?token=Hk41&state=q8Rz"), TokenPayload(token: "Hk41"))
        XCTAssertNil(TokenPayload(parsing: "https://link.apron.chat/#server=wss://chat.example/ws&room=general"))
        XCTAssertNil(TokenPayload(parsing: "two words"))
        XCTAssertNil(TokenPayload(parsing: ""))
    }

    func testDisplayNamesMergeCurrentObjectsAndDisambiguate() {
        var users = UserDirectory()
        users.replace(with: UserObject(["user_id": "ada", "name": "Ada", "avatar": "https://a.example/a.png"])!)
        users.merge(UserObject(["user_id": "ada", "avatar": ""])!)
        XCTAssertEqual(users.user("ada"), ["user_id": "ada", "name": "Ada"])
        XCTAssertEqual(users.displayName(for: UserObject(["user_id": "ada", "name": "Old"])!), "Ada")
        XCTAssertEqual(users.displayName(for: UserObject(["user_id": "carol", "name": "Carol"])!), "Carol")
        XCTAssertEqual(users.displayName(for: UserObject(["user_id": "dave"])!), "dave")
        users.merge(UserObject(["user_id": "ada2", "name": "Ada"])!)
        XCTAssertEqual(users.displayName(for: UserObject(["user_id": "ada"])!), "Ada (@ada)")
    }

    func testLogIDNeighbours() {
        XCTAssertEqual(LogID("1724803200042")?.predecessor, LogID("1724803200041"))
        XCTAssertEqual(LogID("9")?.successor, LogID("10"))
        XCTAssertNil(LogID("1")?.predecessor)
    }
}

@MainActor
final class SessionStoreTests: XCTestCase {
    func testEachServerKeepsItsOwnSessionAndAccountsPersist() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "apron-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let transports = Transports()
        let tokens = InMemoryTokenStore()
        let counter = Mutex(0)
        let environment = ServerSession.Environment(makeTransport: { _ in transports.next() },
                                                    makeRequestID: { counter.withLock { $0 += 1; return "c\($0)" } })
        let store = SessionStore(serverStore: ServerStore(directory: directory), tokens: tokens, environment: environment)
        let first = ServerRecord(url: URL(string: "wss://one.example/ws")!)
        let second = ServerRecord(url: URL(string: "wss://two.example/ws")!)
        let one = store.add(first)
        store.add(second)
        XCTAssertEqual(store.records.map(\.label), ["one.example", "two.example"])

        await eventually("connected") { one.status == .signedOut }
        let socket = transports.made.withLock { $0[0] }
        let signIn = Task { try await one.signIn(.token("tok")) }
        await eventually("auth sent") { await socket.sentLog.count == 2 }
        let sent = await socket.sentLog
        let authID = try XCTUnwrap(JSONValue(parsing: sent[0])["id"])
        let roomsID = try XCTUnwrap(JSONValue(parsing: sent[1])["id"])
        await socket.deliver(["id": authID, "result": ["you": ["user_id": "ada"]]])
        await socket.deliver(["id": roomsID, "result": ["joined": []]])
        _ = try await signIn.value

        XCTAssertEqual(try tokens.token(for: first.id), "tok")
        XCTAssertNil(try tokens.token(for: second.id))
        XCTAssertNil(store.session(for: second.id)?.you)
        let saved = try ServerStore(directory: directory).load()
        XCTAssertEqual(saved.map(\.account), [ServerRecord.Account(userID: "ada", scheme: "token"), nil])

        await store.remove(first.id)
        XCTAssertNil(try tokens.token(for: first.id))
        XCTAssertEqual(try ServerStore(directory: directory).load().map(\.id), [second.id])
        await store.remove(second.id)
    }
}
