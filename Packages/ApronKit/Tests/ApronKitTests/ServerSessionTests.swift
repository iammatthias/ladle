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
    let positions = InMemoryReadPositionStore()
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
        session = ServerSession(record: record, tokens: tokens, positions: positions, environment: environment)
    }

    override func tearDown() async throws {
        await session.stop()
    }

    private func transport(_ index: Int) async -> FakeTransport {
        await eventually("transport \(index)") { transports.made.withLock { $0.count > index } }
        return transports.made.withLock { $0[index] }
    }

    /// Queues a transport whose greeting lists `capabilities`, with `ext` when given.
    private func queueTransport(capabilities: [String], ext: JSONValue? = nil, more: [String: JSONValue] = [:]) -> FakeTransport {
        var params: [String: JSONValue] = ["apron": 9, "auth": ["email", "token", "guest"], "capabilities": .array(capabilities.map(JSONValue.string))]
        if let ext { params["ext"] = ext }
        params.merge(more) { _, new in new }
        let transport = FakeTransport()
        transports.queued.withLock { $0.append(transport) }
        Task { await transport.deliver(["method": "server", "params": .object(params)]) }
        return transport
    }

    private func frames(_ transport: FakeTransport, count: Int) async -> [String] {
        await eventually("\(count) frames") { await transport.sentLog.count >= count }
        return await Array(transport.sentLog.prefix(count))
    }

    private func frame(_ transport: FakeTransport, _ index: Int) async -> String {
        await frames(transport, count: index + 1).last ?? ""
    }

    private func signInAsGuest(on transport: FakeTransport, you: JSONValue = ["user_id": "ada", "name": "Ada"]) async throws {
        await eventually("signed out") { session.status == .signedOut }
        let signIn = Task { try await session.signIn(.guest(name: nil)) }
        _ = await frames(transport, count: 2)
        await transport.deliver(["id": "c1", "result": ["you": you, "token": "t1"]])
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

    func testAUserOnlyReadsWherePermissionsSayWriteIsOff() async throws {
        let readOnly = queueTransport(capabilities: ["rooms", "ext:permissions"])
        session.start()
        try await signInAsGuest(on: readOnly, you: ["user_id": "guest_1", "name": "Guest", "ext": ["permissions": ["write": false]]])
        XCTAssertTrue(session.isGuest)
        XCTAssertFalse(session.mayWrite)

        let signIn = Task { try await session.signIn(.token("t9")) }
        _ = await frames(readOnly, count: 4)
        await readOnly.deliver(["id": "c3", "result": ["you": ["user_id": "ada", "name": "Ada", "ext": ["permissions": [:]]]]])
        await readOnly.deliver(["id": "c4", "result": ["joined": []]])
        _ = try await signIn.value
        XCTAssertTrue(session.mayWrite, "an account the server lets write")

        await readOnly.deliver(["method": "user", "params": ["you": ["user_id": "ada", "ext": ["permissions": ["write": false]]]]])
        await eventually("write taken away") { !session.mayWrite }
        XCTAssertFalse(session.isGuest, "write: false holds for any account, not only guests")
    }

    func testPermissionsTakeTheirDefaultsKeyByKey() {
        XCTAssertEqual(Permissions(["write": false, "add_members": true, "move_any": true]),
                       { var p = Permissions(); p.write = false; p.addMembers = true; p.moveAny = true; return p }())
        for value: JSONValue? in [nil, [:], ["write": "no", "move_any": 1], ["write", "move_any"]] {
            XCTAssertEqual(Permissions(value), Permissions(), "\(String(describing: value))")
        }
    }

    func testAGuestOnlyReadsOnAServerFromBeforePermissionsThatSaysGuestsDoNotPost() async throws {
        let legacy = queueTransport(capabilities: ["rooms", "ext:settings"], ext: ["settings": ["guest_posting": false]])
        session.start()
        try await signInAsGuest(on: legacy)
        XCTAssertFalse(session.mayWrite)

        let signIn = Task { try await session.signIn(.token("t9")) }
        _ = await frames(legacy, count: 4)
        await legacy.deliver(["id": "c3", "result": ["you": ["user_id": "ada", "name": "Ada", "roles": []]]])
        await legacy.deliver(["id": "c4", "result": ["joined": []]])
        _ = try await signIn.value
        XCTAssertTrue(session.mayWrite, "the old setting held only for guests")
    }

    func testTheServersTitleAndAvatarNameItUnlessTheUserDid() async throws {
        _ = queueTransport(capabilities: [], more: ["title": " Apron Demo ", "description": "The *public* demo", "avatar": "https://cdn.example/icon.png"])
        session.start()
        await eventually("greeted") { session.server != nil }
        XCTAssertEqual(session.serverName, "Apron Demo")
        XCTAssertEqual(session.server?.description, "The *public* demo")
        XCTAssertEqual(session.serverAvatarURL, URL(string: "https://cdn.example/icon.png"))

        var named = record
        named.label = "Work"
        let renamed = ServerSession(record: named, tokens: tokens, positions: positions, environment: .live)
        XCTAssertEqual(renamed.serverName, "Work", "the user's own name wins")
        XCTAssertEqual(ServerSession(record: record, tokens: tokens, positions: positions, environment: .live).serverName, "chat.example",
                       "the address without a title")
    }

    func testAServerAvatarLoadsOnlyWhereAvatarsMay() async throws {
        _ = queueTransport(capabilities: [], more: ["avatar": "http://cdn.example/icon.png"])
        session.start()
        await eventually("greeted") { session.server != nil }
        XCTAssertNil(session.serverAvatarURL)
    }

    func testGuestsWriteUnlessTheServerSaysOtherwise() async throws {
        let settingsWithoutTheKey = queueTransport(capabilities: ["rooms", "ext:settings"], ext: ["settings": ["read_cursors": true]])
        session.start()
        try await signInAsGuest(on: settingsWithoutTheKey)
        XCTAssertTrue(session.mayWrite)
    }

    func testASignUpInviteSendsTheNameAndSavesTheNewAccountsOwnToken() async throws {
        session.start()
        let socket = await transport(0)
        await eventually("signed out") { session.status == .signedOut }
        XCTAssertTrue(SignIn.isSignUpInvite("apron_join_Qm7x"))
        XCTAssertFalse(SignIn.isSignUpInvite("apron_invite_Qm7x"))
        let signUp = Task { try await session.signIn(.signUp(invite: "apron_join_Qm7x", name: "  Ada Okafor ")) }
        let sent = await frame(socket, 0)
        XCTAssertEqual(sent, #"{"id":"c1","method":"auth","params":{"agent":"ladle-ios/test","name":"Ada Okafor","scheme":"token","token":"apron_join_Qm7x"}}"#)
        await socket.deliver(["id": "c1", "result": ["you": ["user_id": "ada_1234", "name": "Ada Okafor", "roles": []], "token": "apron_invite_Zr8"]])
        await socket.deliver(["id": "c2", "result": ["joined": []]])
        _ = try await signUp.value
        XCTAssertEqual(try tokens.token(for: record.id), "apron_invite_Zr8", "the account's own token, not the invite")
        XCTAssertEqual(session.record.account, ServerRecord.Account(userID: "ada_1234", name: "Ada Okafor", scheme: "token"))
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

    func testTheRetentionFloorDropsExpiredSnapshotsAndStopsPaging() async throws {
        session.start()
        let socket = await transport(0)
        try await signInAsGuest(on: socket)
        let open = Task { try await session.open("general") }
        _ = await frame(socket, 2)
        await socket.deliver(["id": "c3", "result": [
            "messages": [message("104", "d"), message("105", "e"), message("106", "f")],
            "reactions": [["log_id": "107", "message_id": "104", "room_id": "general", "reactions": [["from": ["user_id": "ada"], "emojis": ["👍"]]]]],
            "first_log_id": "104", "last_log_id": "107", "more": true, "latest_log_id": "107", "history_log_id": "101",
        ]])
        try await open.value
        XCTAssertTrue(session.canLoadOlder("general"))
        await socket.deliver(["method": "message", "params": [
            "message_id": "104", "log_id": "108", "room_id": "general", "from": ["user_id": "bob"], "body": ["text": "d, edited"],
        ]])

        await socket.deliver(["method": "room_update", "params": ["updated": [
            ["room_id": "general", "log_id": "100", "title": "General", "latest_log_id": "108", "history_log_id": "106"],
        ]]])
        await eventually("expired snapshots dropped") { session.timeline("general").count == 2 }
        XCTAssertEqual(session.timeline("general").map(\.messageID.text), ["104", "106"], "104 was edited above the floor")
        XCTAssertNil(session.store.message(LogID("105")!))
        XCTAssertFalse(session.canLoadOlder("general"), "the page before 104 is below the floor")
        XCTAssertEqual(session.store.floor(of: "general"), LogID("106"))

        await socket.deliver(["method": "room_update", "params": ["updated": [
            ["room_id": "general", "log_id": "100", "title": "General", "latest_log_id": "108", "history_log_id": "102"],
        ]]])
        await socket.deliver(["method": "message", "params": message("105", "e, again")])
        await socket.deliver(["method": "room_update", "params": ["updated": [["room_id": "general", "log_id": "100", "title": "General"]]]])
        await socket.deliver(["method": "message", "params": message("109", "new")])
        await eventually("live message") { session.timeline("general").count == 3 }
        XCTAssertEqual(session.store.floor(of: "general"), LogID("106"), "never lowered, and kept without history_log_id")
        XCTAssertNil(session.store.message(LogID("105")!), "a late record below the floor stays out")

        await socket.deliver(["method": "room_update", "params": ["updated": [
            ["room_id": "general", "log_id": "100", "title": "General", "latest_log_id": "109", "history_log_id": .null],
        ]]])
        await eventually("all history expired") { session.timeline("general").isEmpty }
        XCTAssertEqual(session.store.floor(of: "general"), LogID("110"), "null means nothing is kept: latest + 1")
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
        XCTAssertEqual(session.canLoadOlder("general"), true)

        let older = Task { try await session.loadOlder("general") }
        let olderFrame = await frame(socket, 3)
        XCTAssertEqual(olderFrame, #"{"id":"c4","method":"history","params":{"before":"103","limit":3,"room_id":"general"}}"#)
        await socket.deliver(["id": "c4", "result": [
            "messages": [message("101", "a"), message("102", "b"), message("103", "c")],
            "first_log_id": "101", "last_log_id": "103", "more": false, "latest_log_id": "106", "history_log_id": "101",
        ]])
        try await older.value
        XCTAssertEqual(session.canLoadOlder("general"), false)
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
        await socket.deliver(["method": "message", "params": message("201", "y")])
        await eventually("frames applied") { session.timeline("general").count == 2 }
        XCTAssertEqual(session.readCursors, ["general": LogID("200")!])
        XCTAssertEqual(session.unreadCount(in: "general"), 1, "201 is after the cursor")

        await socket.deliver(activity("ada", "201"))
        await eventually("another device read it") { session.readCursors["general"] == LogID("201") }
        XCTAssertEqual(session.unreadCount(in: "general"), 0)
        XCTAssertEqual(positions.positions(server: record.id, user: "ada"), ["general": LogID("201")!], "kept for the next launch")
    }

    func testMarkReadSendsTheCursorOnlyForward() async throws {
        let socket = queueTransport(capabilities: ["history", "rooms", "activity"])
        session.start()
        try await signInAsGuest(on: socket)
        await session.markRead("general", through: LogID("200")!)
        await session.markRead("general", through: LogID("150")!)
        await session.markRead("general", through: LogID("200")!)
        await session.markRead("general", through: LogID("260")!)
        let sent = await frames(socket, count: 4)
        XCTAssertEqual(Array(sent[2...]), [
            #"{"method":"activity","params":{"read_message_id":"200","room_id":"general"}}"#,
            #"{"method":"activity","params":{"read_message_id":"260","room_id":"general"}}"#,
        ])
        XCTAssertEqual(session.readCursors, ["general": LogID("260")!])
        XCTAssertEqual(session.readPositions, ["general": LogID("260")!])
        XCTAssertEqual(positions.positions(server: record.id, user: "ada"), ["general": LogID("260")!])
    }

    func testWithoutTheActivityCapabilityReadingMovesOnlyThePosition() async throws {
        session.start()
        let socket = await transport(0)
        try await signInAsGuest(on: socket)
        for id in ["101", "102", "103"] { await socket.deliver(["method": "message", "params": message(id, "hi")]) }
        await eventually("messages applied") { session.timeline("general").count == 3 }
        XCTAssertEqual(session.unreadCount(in: "general"), 3)

        await session.markRead("general", through: LogID("103")!)
        let join = Task { try await session.join("other") }
        let third = await frame(socket, 2)
        XCTAssertEqual(third, #"{"id":"c3","method":"room_join","params":{"room_id":"other"}}"#, "nothing went before it")
        await socket.deliver(["id": "c3", "result": [:]])
        _ = try await join.value
        XCTAssertEqual(session.readCursors, [:])
        XCTAssertEqual(session.readPositions, ["general": LogID("103")!])
        XCTAssertEqual(session.unreadCount(in: "general"), 0)

        await socket.deliver(["method": "message", "params": message("104", "later")])
        await eventually("message applied") { session.timeline("general").count == 4 }
        XCTAssertEqual(session.unreadCount(in: "general"), 1)
    }

    func testAServerThatKeepsNoCursorsGetsNoFrameButTheCursorStillMoves() async throws {
        let socket = queueTransport(capabilities: ["history", "rooms", "activity", "ext:settings"], ext: ["settings": ["read_cursors": false]])
        session.start()
        try await signInAsGuest(on: socket)
        await session.markRead("general", through: LogID("200")!)
        let join = Task { try await session.join("other") }
        let third = await frame(socket, 2)
        XCTAssertEqual(third, #"{"id":"c3","method":"room_join","params":{"room_id":"other"}}"#, "nothing went before it")
        await socket.deliver(["id": "c3", "result": [:]])
        _ = try await join.value
        XCTAssertEqual(session.readCursors, ["general": LogID("200")!])
        XCTAssertEqual(session.readPositions, ["general": LogID("200")!])
    }

    func testTheNewLineGoesBeforeTheFirstUnreadMessageYouDidNotWrite() async throws {
        session.start()
        let socket = await transport(0)
        try await signInAsGuest(on: socket)
        let open = Task { try await session.open("general") }
        _ = await frame(socket, 2)
        await socket.deliver(["id": "c3", "result": [
            "messages": [message("120", "a"), message("130", "b")], "first_log_id": "120", "last_log_id": "130", "more": true,
            "latest_log_id": "130", "history_log_id": "100",
        ]])
        try await open.value
        XCTAssertEqual(session.canLoadOlder("general"), true)
        XCTAssertNil(session.newLine(in: "general", after: nil), "nothing known")
        XCTAssertNil(session.newLine(in: "general", after: LogID("110")!), "the first unread may be in the page before")
        XCTAssertEqual(session.newLine(in: "general", after: LogID("120")!), LogID("130"))
        XCTAssertNil(session.newLine(in: "general", after: LogID("130")!), "all read")

        await socket.deliver(["method": "message", "params": [
            "message_id": "140", "log_id": "140", "room_id": "general", "from": ["user_id": "ada"], "body": ["text": "mine"],
        ]])
        await socket.deliver(["method": "message", "params": message("150", "c")])
        await eventually("messages applied") { session.timeline("general").count == 4 }
        XCTAssertNil(session.newLine(in: "general", after: LogID("130")!), "the first message after is your own")
        XCTAssertEqual(session.newLine(in: "general", after: LogID("140")!), LogID("150"))
    }

    // MARK: Deleted messages

    private func tombstone(_ id: String, from: String = "bob") -> JSONValue {
        ["message_id": .string(id), "log_id": .string(id), "room_id": "general", "from": ["user_id": .string(from)], "deleted": true]
    }

    func testADeletedMessageLeavesTheTimelineAndItsCountsButNotTheStore() async throws {
        session.start()
        let socket = await transport(0)
        try await signInAsGuest(on: socket)
        for id in ["101", "102", "103"] { await socket.deliver(["method": "message", "params": message(id, "hi")]) }
        await eventually("messages applied") { session.timeline("general").count == 3 }
        XCTAssertEqual(session.unreadCount(in: "general"), 3)
        XCTAssertEqual(session.newLine(in: "general", after: LogID("101")!), LogID("102"))

        await socket.deliver(["method": "message", "params": tombstone("102")])
        await eventually("deletion applied") { session.timeline("general").count == 2 }
        XCTAssertEqual(session.timeline("general").map(\.messageID.text), ["101", "103"])
        XCTAssertEqual(session.unreadCount(in: "general"), 2)
        XCTAssertEqual(session.newLine(in: "general", after: LogID("101")!), LogID("103"), "the line skips the deleted message")
        XCTAssertEqual(session.store.message(LogID("102")!)?.isTombstone, true, "the store keeps the tombstone for the replay rule")
        let projected = session.store.projection()["rooms"]?.arrayValue?.first?["messages"]?.arrayValue ?? []
        XCTAssertEqual(projected.map { $0["deleted"]?.boolValue }, [nil, true, nil])
    }

    func testDeletingYourOwnMessageDoesNotUnreadWhatCameBeforeIt() async throws {
        session.start()
        let socket = await transport(0)
        try await signInAsGuest(on: socket)
        await socket.deliver(["method": "message", "params": message("101", "hi")])
        await socket.deliver(["method": "message", "params": [
            "message_id": "102", "log_id": "102", "room_id": "general", "from": ["user_id": "ada"], "body": ["text": "mine"],
        ]])
        await eventually("messages applied") { session.timeline("general").count == 2 }
        XCTAssertEqual(session.unreadCount(in: "general"), 0)

        await socket.deliver(["method": "message", "params": tombstone("102", from: "ada")])
        await eventually("deletion applied") { session.timeline("general").count == 1 }
        XCTAssertEqual(session.readThrough("general"), LogID("102"))
        XCTAssertEqual(session.unreadCount(in: "general"), 0)
    }

    func testAPageOfOnlyDeletedMessagesStillMovesPagingBack() async throws {
        session.start()
        let socket = await transport(0)
        try await signInAsGuest(on: socket)
        let open = Task { try await session.open("general") }
        _ = await frame(socket, 2)
        await socket.deliver(["id": "c3", "result": [
            "messages": [tombstone("120"), message("130", "b")], "first_log_id": "120", "last_log_id": "130", "more": true,
            "latest_log_id": "130", "history_log_id": "100",
        ]])
        try await open.value
        XCTAssertEqual(session.timeline("general").map(\.messageID.text), ["130"])
        XCTAssertEqual(session.newLine(in: "general", after: LogID("125")!), LogID("130"), "the loaded tombstone at 120 shows nothing unread is older")

        let older = Task { try await session.loadOlder("general") }
        _ = await frame(socket, 3)
        await socket.deliver(["id": "c4", "result": [
            "messages": [tombstone("110")], "first_log_id": "110", "last_log_id": "110", "more": true,
            "latest_log_id": "130", "history_log_id": "100",
        ]])
        try await older.value
        XCTAssertEqual(session.timeline("general").map(\.messageID.text), ["130"])
        XCTAssertEqual(session.histories["general"]?.olderBefore, LogID("109"), "the timeline shows the same messages, so the view pages on this")
    }

    func testTheReadCursorsSettingCountsOnlyUnderItsCapability() {
        func info(_ capabilities: [String], ext: JSONValue? = nil) -> ServerInfo {
            var params: [String: JSONValue] = ["apron": 9, "auth": ["token"], "capabilities": .array(capabilities.map(JSONValue.string))]
            if let ext { params["ext"] = ext }
            return ServerInfo(params: .object(params))!
        }
        XCTAssertTrue(info(["activity"]).keepsReadCursors)
        XCTAssertTrue(info(["activity"], ext: ["settings": ["read_cursors": false]]).keepsReadCursors, "no ext:settings capability")
        XCTAssertTrue(info(["activity", "ext:settings"], ext: ["settings": ["guest_posting": false]]).keepsReadCursors)
        XCTAssertFalse(info(["activity", "ext:settings"], ext: ["settings": ["read_cursors": false]]).keepsReadCursors)
    }

    func testKeptPositionsLoadForTheSignedInUserOnly() async throws {
        positions.advance("general", to: LogID("150")!, server: record.id, user: "ada")
        positions.advance("general", to: LogID("900")!, server: record.id, user: "bob")
        session.start()
        let socket = await transport(0)
        try await signInAsGuest(on: socket)
        XCTAssertEqual(session.readPositions, ["general": LogID("150")!])
        for id in ["140", "160"] { await socket.deliver(["method": "message", "params": message(id, "hi")]) }
        await eventually("messages applied") { session.timeline("general").count == 2 }
        XCTAssertEqual(session.readThrough("general"), LogID("150"))
        XCTAssertEqual(session.unreadCount(in: "general"), 1)
    }

    // MARK: Reading

    func testUnreadCountsOthersMessagesWithoutAServerCursor() async throws {
        session.start()
        let socket = await transport(0)
        try await signInAsGuest(on: socket)
        for id in ["101", "102", "103"] { await socket.deliver(["method": "message", "params": message(id, "hi")]) }
        await socket.deliver(["method": "message", "params": [
            "message_id": "104", "log_id": "104", "room_id": "general", "from": ["user_id": "ada"], "body": ["text": "mine"],
        ]])
        await socket.deliver(["method": "message", "params": message("105", "after yours")])
        await eventually("messages applied") { session.timeline("general").count == 5 }
        XCTAssertEqual(session.unreadCount(in: "general"), 1, "your own message at 104 says you had read through it")
        let sent = await socket.sentLog
        XCTAssertEqual(sent.count, 2, "nothing was sent after auth and room_list: \(sent)")
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
        await socket.deliver(["method": "reactions", "params": [
            "log_id": "203", "message_id": "201", "room_id": "general", "reactions": [["from": ["user_id": "ada"], "emojis": ["🎉", "❤"]]],
        ]])
        await eventually("heart installed") { session.store.reactions(on: LogID("201")!)?.map(\.key) == ["❤", "🎉"] }
        try await expect(#"{"id":"c8","method":"reactions","params":{"emojis":["🎉"],"message_id":"201"}}"#) {
            try await self.session.toggleReaction("❤️", on: LogID("201")!)
        }
        try await expect(#"{"id":"c9","method":"room_join","params":{"room_id":"ops"}}"#) { try await self.session.join("ops") }
        try await expect(#"{"id":"c10","method":"room_leave","params":{"room_id":"ops"}}"#) { try await self.session.leave("ops") }
        try await expect(#"{"id":"c11","method":"room_set","params":{"parent_room_id":"general","title":"Deploy"}}"#,
                         reply: ["room_id": "300"]) { try await self.session.createRoom(title: "Deploy", parentRoomID: "general") }
    }

    /// Signs in with a token as `you`, in `general` and its thread `130`, on a server listing `capabilities`.
    private func signInWithRooms(_ you: JSONValue, capabilities: [String]) async throws -> FakeTransport {
        try tokens.setToken("t1", for: record.id)
        let socket = queueTransport(capabilities: capabilities)
        session.start()
        _ = await frames(socket, count: 2)
        await socket.deliver(["id": "c1", "result": ["you": you]])
        await socket.deliver(["id": "c2", "result": ["joined": [
            ["room_id": "general", "log_id": "100", "title": "General", "latest_log_id": "100", "history_log_id": "100"],
            ["room_id": "130", "log_id": "130", "parent_room_id": "general", "title": "Deploy", "latest_log_id": "130", "history_log_id": "130"],
        ]]])
        await eventually("signed in") { session.status == .signedIn && session.joinedRoomIDs.count == 2 }
        return socket
    }

    func testAModeratorWithMoveAnyMovesSomeoneElsesMessageUntilThePermissionGoes() async throws {
        let socket = try await signInWithRooms(["user_id": "mia", "name": "Mia", "roles": ["mod"], "ext": ["permissions": ["move_any": true, "add_members": true, "write": 7]]],
                                               capabilities: ["history", "edit", "rooms", "ext:permissions"])
        XCTAssertTrue(session.permissions.moveAny)
        XCTAssertTrue(session.permissions.write, "a value of the wrong type takes the default")
        await socket.deliver(["method": "message", "params": [
            "message_id": "200", "log_id": "200", "room_id": "130", "from": ["user_id": "ada"],
            "body": ["text": "helo"], "reply_to": ["message_id": "150"], "ext": ["k": 1],
        ]])
        await socket.deliver(["method": "message", "params": ["message_id": "201", "log_id": "201", "room_id": "general", "from": ["user_id": "mia"], "body": ["text": "mine"]]])
        await eventually("messages installed") { session.store.message(LogID("201")!) != nil }
        let adas = try XCTUnwrap(session.store.message(LogID("200")!))
        let mine = try XCTUnwrap(session.store.message(LogID("201")!))
        XCTAssertTrue(session.mayMove(adas))
        XCTAssertEqual(session.moveDestinations(for: adas), ["general"], "out of the thread")
        XCTAssertEqual(session.moveDestinations(for: mine), ["130"], "into a thread")

        let move = Task { try await session.move(adas, to: "general") }
        let sent = await frame(socket, 2)
        XCTAssertEqual(sent, #"{"id":"c3","method":"message","params":{"body":{"text":"helo"},"ext":{"k":1},"message_id":"200","reply_to":{"message_id":"150"},"room_id":"general"}}"#)
        await socket.deliver(["id": "c3", "result": [:]])
        try await move.value

        await socket.deliver(["method": "user", "params": ["you": ["user_id": "mia", "ext": ["permissions": [:]]]]])
        await eventually("permissions cleared") { session.permissions == Permissions() }
        XCTAssertFalse(session.mayMove(adas))
        XCTAssertTrue(session.mayMove(mine), "your own message moves without a permission")
    }

    func testEditSendsTheStoredExtAndReplyAgain() async throws {
        let socket = try await signInWithRooms(["user_id": "mia"], capabilities: ["history", "edit", "rooms"])
        await socket.deliver(["method": "message", "params": [
            "message_id": "200", "log_id": "200", "room_id": "general", "from": ["user_id": "mia"],
            "body": ["text": "helo"], "reply_to": ["message_id": "150"], "ext": ["k": 1],
        ]])
        await eventually("message installed") { session.store.message(LogID("200")!) != nil }
        let original = try XCTUnwrap(session.store.message(LogID("200")!))
        let edit = Task { try await session.edit(original, text: "hello") }
        let sent = await frame(socket, 2)
        XCTAssertEqual(sent, #"{"id":"c3","method":"message","params":{"body":{"text":"hello"},"ext":{"k":1},"message_id":"200","reply_to":{"message_id":"150"},"room_id":"general"}}"#)
        await socket.deliver(["id": "c3", "result": [:]])
        try await edit.value
    }

    func testOnlyAdminsAndModeratorsCreateRoomsWhereTheServerStatesPermissions() async throws {
        let socket = try await signInWithRooms(["user_id": "mia", "roles": []], capabilities: ["rooms", "ext:permissions"])
        XCTAssertFalse(session.mayCreateRooms)
        for (roles, may) in [(["announce"], false), (["mod"], true), (["moderator"], true), (["admin", "bot"], true)] {
            await socket.deliver(["method": "user", "params": ["you": ["user_id": "mia", "roles": .array(roles.map(JSONValue.string))]]])
            await eventually("roles \(roles)") { session.you?.roles == roles }
            XCTAssertEqual(session.mayCreateRooms, may, "\(roles)")
        }
    }

    func testAnyoneCreatesRoomsWhereTheServerStatesNoPermissions() async throws {
        _ = try await signInWithRooms(["user_id": "mia"], capabilities: ["rooms"])
        XCTAssertTrue(session.mayCreateRooms)
    }

    func testPermissionsCountOnlyWithTheCapability() async throws {
        _ = try await signInWithRooms(["user_id": "mia", "ext": ["permissions": ["move_any": true, "write": false]]], capabilities: ["history", "edit", "rooms"])
        XCTAssertEqual(session.permissions, Permissions())
        XCTAssertTrue(session.mayWrite)
        let other = MessageSnapshot(messageID: LogID("200")!, logID: LogID("200")!, roomID: "general", from: UserObject(["user_id": "ada"])!)
        XCTAssertFalse(session.mayMove(other))
    }

    func testMentionsCommandsAndDoubleSlashMessages() async throws {
        session.start()
        let socket = await transport(0)
        try await signInAsGuest(on: socket)
        let mention = Task { try await session.send("hi @Bob", in: "general", mentions: ["bob"]) }
        let sent1 = await frame(socket, 2)
        XCTAssertEqual(sent1, #"{"id":"c3","method":"message","params":{"body":{"format":"plain","mentions":["bob"],"text":"hi @Bob"},"room_id":"general"}}"#)
        await socket.deliver(["id": "c3", "result": ["message_id": "300"]])
        let posted = try await mention.value
        XCTAssertEqual(posted, LogID("300"))
        let command = Task { try await session.send("/help", in: "general") }
        let sent2 = await frame(socket, 3)
        XCTAssertEqual(sent2, #"{"id":"c4","method":"command","params":{"body":{"format":"plain","text":"/help"},"room_id":"general"}}"#)
        await socket.deliver(["id": "c4", "result": [:]])
        let ran = try await command.value
        XCTAssertNil(ran)
        let slash = Task { try await session.send("//shrug", in: "general") }
        let sent3 = await frame(socket, 4)
        XCTAssertEqual(sent3, #"{"id":"c5","method":"message","params":{"body":{"format":"plain","text":"/shrug"},"room_id":"general"}}"#)
        await socket.deliver(["id": "c5", "result": ["message_id": "301"]])
        _ = try await slash.value
    }

    func testTheOutboxHoldsAMessageUntilSignInAndResendsItWithTheSameID() async throws {
        session.start()
        let first = await transport(0)
        try await signInAsGuest(on: first)
        await first.dropFromServer()
        await eventually("reconnecting") { if case .reconnecting = session.status { true } else { false } }
        session.post("queued", in: "general")
        XCTAssertEqual(session.outbox.map(\.text), ["queued"])
        XCTAssertEqual(session.outbox.first?.state, .sending)

        let resent = #"{"id":"q-c3","method":"message","params":{"body":{"format":"plain","text":"queued"},"room_id":"general"}}"#
        clock.release()
        let second = await transport(1)
        _ = await frames(second, count: 2)
        await second.deliver(["id": "c4", "result": ["you": ["user_id": "ada", "name": "Ada"]]])
        await second.deliver(["id": "c5", "result": ["joined": [["room_id": "general"]]]])
        let sent4 = await frame(second, 2)
        XCTAssertEqual(sent4, resent)
        await second.dropFromServer()
        await eventually("reconnecting again") { if case .reconnecting = session.status { true } else { false } }
        XCTAssertEqual(session.outbox.count, 1, "a dropped connection leaves it queued")

        clock.release()
        let third = await transport(2)
        _ = await frames(third, count: 2)
        await third.deliver(["id": "c6", "result": ["you": ["user_id": "ada", "name": "Ada"]]])
        await third.deliver(["id": "c7", "result": ["joined": [["room_id": "general"]]]])
        let sent5 = await frame(third, 2)
        XCTAssertEqual(sent5, resent, "the same id across reconnects")
        await third.deliver(["id": "q-c3", "result": ["message_id": "400"]])
        await eventually("sent and removed") { session.outbox.isEmpty }
    }

    func testARefusedQueuedMessageStaysAsNotSent() async throws {
        session.start()
        let socket = await transport(0)
        try await signInAsGuest(on: socket)
        session.post("too much", in: "general")
        _ = await frame(socket, 2)
        await socket.deliver(["id": "q-c3", "error": ["code": -32003, "message": "Too large"]])
        await eventually("failed") { session.outbox.first?.state == .failed("Too long for this server.") }
        session.discard(session.outbox[0].id)
        XCTAssertTrue(session.outbox.isEmpty)
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

    func testAScannedSignInFillsTheServerOnlyWhenAddingOne() {
        let link = "https://link.apron.chat/#server=wss://chat.example/ws&token=inv_Qm7x"
        let saved = URL(string: "wss://chat.example/ws")!
        XCTAssertEqual(SignInFill(link, signingInTo: nil), .serverAndToken(server: saved, token: "inv_Qm7x"))
        XCTAssertEqual(SignInFill(link, signingInTo: saved), .token("inv_Qm7x"))
        XCTAssertEqual(SignInFill("st_abc123", signingInTo: nil), .token("st_abc123"))
        XCTAssertEqual(SignInFill("st_abc123", signingInTo: saved), .token("st_abc123"))
        XCTAssertEqual(SignInFill("apron:?token=Hk41", signingInTo: nil), .token("Hk41"))
        XCTAssertEqual(SignInFill(link, signingInTo: URL(string: "wss://other.example/ws")!),
                       .otherServer(saved))
        XCTAssertNil(SignInFill("https://example.com/menu", signingInTo: nil))
        XCTAssertNil(SignInFill("WIFI:S:Cafe;T:WPA;P:hunter2;;", signingInTo: nil))
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
