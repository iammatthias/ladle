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

    /// Real time moved on by the sleeps released so far, so a wait the session notes by the wall
    /// clock is over once the sleep for it is.
    var now: Date {
        let count = released.withLock { $0 }
        let slept = recorded.prefix(count).reduce(Duration.zero, +)
        return Date().addingTimeInterval(Double(slept.components.seconds) + Double(slept.components.attoseconds) / 1e18)
    }
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

/// Stands in for the connection-status probe: answers from a queue and records each request.
final class Probes: Sendable {
    let queued = Mutex<[ProbeResponse]>([])
    let requests = Mutex<[String]>([])

    func answer(_ url: URL, _ origin: String?) throws -> ProbeResponse {
        requests.withLock { $0.append("\(url.absoluteString) \(origin ?? "-")") }
        guard let next = queued.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) else { throw URLError(.cannotConnectToHost) }
        return next
    }

    func queue(_ status: Int, header: Bool = true, retryAfter: String? = nil, body: String) {
        var headers: [String: String] = [:]
        if header { headers["apron-connection-status"] = "1" }
        if let retryAfter { headers["retry-after"] = retryAfter }
        queued.withLock { $0.append(ProbeResponse(status: status, headers: headers, body: Data(body.utf8))) }
    }
}

@MainActor
final class ServerSessionTests: XCTestCase {
    static let greeting: JSONValue = ["method": "server", "params": [
        "apron": 9, "auth": ["email", "token", "guest"], "capabilities": ["history", "edit", "rooms", "reactions", "command"],
    ]]
    let record = ServerRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, url: URL(string: "wss://chat.example/ws")!)
    let tokens = InMemoryTokenStore()
    let positions = InMemoryReadPositionStore()
    let clock = FakeClock()
    let transports = Transports()
    let probes = Probes()
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
            pageSize: 3,
            fetchConnectionStatus: { [probes] url, origin in try probes.answer(url, origin) },
            readCursorInterval: .milliseconds(100),
            typing: TypingTimes(seconds: 15, refresh: .milliseconds(300), idle: .milliseconds(150), longest: .milliseconds(400)),
            now: { clock.now }
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

        let account = queueTransport(capabilities: ["rooms", "ext:permissions"])
        let signIn = Task { try await session.signIn(.token("t9")) }
        _ = await frames(account, count: 2)
        await account.deliver(["id": "c3", "result": ["you": ["user_id": "ada", "name": "Ada", "ext": ["permissions": [:]]]]])
        await account.deliver(["id": "c4", "result": ["joined": []]])
        _ = try await signIn.value
        XCTAssertTrue(session.mayWrite, "an account the server lets write")

        await account.deliver(["method": "user", "params": ["you": ["user_id": "ada", "ext": ["permissions": ["write": false]]]]])
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

        let account = queueTransport(capabilities: ["rooms", "ext:settings"], ext: ["settings": ["guest_posting": false]])
        let signIn = Task { try await session.signIn(.token("t9")) }
        _ = await frames(account, count: 2)
        await account.deliver(["id": "c3", "result": ["you": ["user_id": "ada", "name": "Ada", "roles": []]]])
        await account.deliver(["id": "c4", "result": ["joined": []]])
        _ = try await signIn.value
        XCTAssertTrue(session.mayWrite, "the old setting held only for guests")
    }

    func testTheServersTitleAndAvatarNameItUnlessTheUserDid() async throws {
        _ = queueTransport(capabilities: [], more: ["title": " Apron Demo ", "description": "The *public* demo", "avatar": "https://cdn.example/icon.png"])
        session.start()
        await eventually("greeted") { session.server != nil }
        XCTAssertEqual(session.serverName, "Apron Demo")
        XCTAssertEqual(session.server?.description, "The *public* demo")
        XCTAssertNil(session.serverAvatarURL, "an avatar on a site nobody trusts does not show")
        session.mediaSettings.trust("https://cdn.example")
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

    func testSigningInAgainOpensANewConnectionWithoutResumingTheOldIdentity() async throws {
        session.start()
        let guest = await transport(0)
        try await signInAsGuest(on: guest)
        let signIn = Task { try await session.signIn(.token("device")) }
        let fresh = await transport(1)
        let sent = await frames(fresh, count: 2)
        XCTAssertEqual(sent.first, #"{"id":"c3","method":"auth","params":{"agent":"ladle-ios/test","scheme":"token","token":"device"}}"#)
        await fresh.deliver(["id": "c3", "result": ["you": ["user_id": "grace", "name": "Grace"]]])
        await fresh.deliver(["id": "c4", "result": ["joined": []]])
        _ = try await signIn.value
        XCTAssertEqual(session.you?.userID, "grace")
        XCTAssertEqual(try tokens.token(for: record.id), "device")
        let guestFrames = await guest.sentLog.count
        XCTAssertEqual(guestFrames, 2)
    }

    func testSigningInAfterTheServerRevokedTheTokenConnectsAgain() async throws {
        session.start()
        let first = await transport(0)
        try await signInAsGuest(on: first)
        await first.close(code: 1008, reason: "Bot token replaced; sign in with the new one")
        await eventually("stopped") { session.status == .stopped(.signedOut) }
        let signIn = Task { try await session.signIn(.token("new")) }
        let second = await transport(1)
        let sent = await frames(second, count: 1)
        XCTAssertEqual(sent, [#"{"id":"c3","method":"auth","params":{"agent":"ladle-ios/test","scheme":"token","token":"new"}}"#])
        await second.deliver(["id": "c3", "result": ["you": ["user_id": "ada", "name": "Ada"]]])
        await second.deliver(["id": "c4", "result": ["joined": []]])
        _ = try await signIn.value
        XCTAssertEqual(session.status, .signedIn)
        XCTAssertNil(session.signInNeeded)
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
        XCTAssertEqual(post, #"{"id":"c3","method":"message","params":{"body":{"format":"markdown","text":"hello"},"room_id":"general"}}"#)
        await first.dropFromServer()
        do {
            _ = try await posting.value
            XCTFail("a pending request fails when the connection drops")
        } catch let error as Connection.Failure {
            XCTAssertEqual(error, .closed)
        }

        await eventually("first backoff") { clock.recorded.count == 1 }
        XCTAssertEqual(session.status, .reconnecting(attempt: 1, delay: .seconds(1)))
        clock.release()
        await eventually("second backoff") { clock.recorded.count == 2 }
        clock.release()
        await eventually("third backoff") { clock.recorded.count == 3 }
        XCTAssertEqual(clock.recorded, [.seconds(1), .seconds(2), .seconds(4)])
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
        XCTAssertEqual(delays, [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(32), .seconds(60), .seconds(60), .seconds(60)])
        XCTAssertEqual(ServerSession.backoff(attempt: 2, jitter: 0.5), .seconds(1))
        XCTAssertEqual(ServerSession.backoff(attempt: 9, jitter: 1.5), .seconds(90))
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

    func testCloseCodesSayWhetherAndWhenToReconnect() {
        XCTAssertEqual(CloseAdvice(CloseFrame(code: 1001, reason: "Connection idle; reconnect to recover")), .reconnect)
        XCTAssertEqual(CloseAdvice(CloseFrame(code: 1011, reason: "Delivery failed; reconnect to recover")), .reconnect)
        XCTAssertEqual(CloseAdvice(CloseFrame(code: 1008, reason: "Too many pending frames")), .reconnect)
        XCTAssertEqual(CloseAdvice(CloseFrame(code: 1013, reason: "Demo capacity reached; try after daily reset")), .backOff)
        XCTAssertEqual(CloseAdvice(CloseFrame(code: 1008, reason: "Authentication timed out")), .awaitSignIn)
        XCTAssertEqual(CloseAdvice(CloseFrame(code: 1008, reason: "Removed by an admin")), .credentialsRevoked("Removed by an admin"))
    }

    func testAClosedOverReplacedCredentialsForgetsTheTokenAndWaitsForSignIn() async throws {
        session.start()
        let socket = await transport(0)
        try await signInAsGuest(on: socket)
        await socket.close(code: 1008, reason: "Device token replaced; sign in with the new one")
        await eventually("stopped") { session.status == .stopped(.signedOut) }
        XCTAssertNil(try tokens.token(for: record.id))
        XCTAssertNil(session.record.account)
        XCTAssertEqual(session.signInNeeded, "Device token replaced; sign in with the new one")
        XCTAssertEqual(clock.recorded, [])
        XCTAssertEqual(transports.made.withLock { $0.count }, 1)
    }

    func testAConnectionThatNeverSignedInIsNotReopenedAfterTheAuthDeadline() async throws {
        session.start()
        let socket = await transport(0)
        await eventually("signed out") { session.status == .signedOut }
        await socket.close(code: 1008, reason: "Authentication timed out")
        await eventually("stopped") { session.status == .stopped(.signedOut) }
        XCTAssertNil(session.signInNeeded)
        XCTAssertEqual(clock.recorded, [])
    }

    func testAPolicyCloseThatANewConnectionClearsReconnectsWithBackoff() async throws {
        session.start()
        let socket = await transport(0)
        try await signInAsGuest(on: socket)
        await socket.close(code: 1008, reason: "Frame rate limit reached")
        await eventually("backoff") { clock.recorded.count == 1 }
        XCTAssertEqual(clock.recorded, [.seconds(1)])
        XCTAssertEqual(try tokens.token(for: record.id), "t1")
    }

    func testATryAgainLaterCloseWaitsMinutes() async throws {
        session.start()
        let socket = await transport(0)
        try await signInAsGuest(on: socket)
        await socket.close(code: 1013, reason: "Frame rate limit reached")
        await eventually("backoff") { clock.recorded.count == 1 }
        XCTAssertEqual(clock.recorded, [.seconds(120)])
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

    func testAResumeRefusedWithRetryAfterWaitsItOutAndKeepsTheToken() async throws {
        try tokens.setToken("t1", for: record.id)
        session.start()
        let socket = await transport(0)
        _ = await frames(socket, count: 2)
        await socket.deliver(["id": "c1", "error": ["code": -32002, "message": "Connection limit reached for this account",
                                                    "data": ["retry_after": 60]]])
        await eventually("backoff") { clock.recorded.count == 1 }
        XCTAssertEqual(clock.recorded, [.seconds(60)])
        XCTAssertEqual(try tokens.token(for: record.id), "t1")
    }

    func testSuspendSendsTheReadCursorStillWaitingForItsInterval() async throws {
        let socket = queueTransport(capabilities: ["history", "rooms", "activity"])
        session.start()
        try await signInAsGuest(on: socket)
        await session.markRead("general", through: LogID("201")!)
        let waiting = Task { await session.markRead("general", through: LogID("202")!) }
        try await Task.sleep(for: .milliseconds(10))
        await session.suspend(deadline: .zero)
        await waiting.value
        let log = await socket.sentLog
        XCTAssertEqual(Array(log[2...]), [
            #"{"method":"activity","params":{"read_message_id":"201","room_id":"general"}}"#,
            #"{"method":"activity","params":{"read_message_id":"202","room_id":"general"}}"#,
        ])
    }

    func testStartingAgainWhileSuspendingKeepsTheConnection() async throws {
        let socket = queueTransport(capabilities: ["history", "rooms", "status"])
        session.start()
        try await signInAsGuest(on: socket)
        let suspending = Task { await session.suspend() }
        _ = await frames(socket, count: 3)
        session.start()
        await socket.deliver(["id": "c3", "result": [:]])
        await suspending.value
        XCTAssertEqual(session.status, .signedIn)
        let closed = await socket.closed
        XCTAssertFalse(closed)
        XCTAssertEqual(transports.made.withLock { $0.count }, 1)
    }

    // MARK: Connection status

    private func failUpgrade(status: Int? = nil) {
        transports.queued.withLock { $0.append(FakeTransport(dropped: status == nil, rejectedWith: status)) }
    }

    func testAnUnavailableServerShowsItsMessageAndWaitsOutRetryAfter() async throws {
        failUpgrade(status: 503)
        probes.queue(503, retryAfter: "120", body: #"{"error":"Demo temporarily unavailable"}"#)
        session.start()
        await eventually("reconnecting") { session.unavailableMessage != nil && clock.recorded.count == 1 }
        XCTAssertEqual(session.unavailableMessage, "Demo temporarily unavailable")
        XCTAssertEqual(clock.recorded, [.seconds(120)])
        XCTAssertEqual(probes.requests.withLock { $0 }, ["https://chat.example/ws?apron_connection_status=1 https://chat.example"])

        clock.release()
        await eventually("connected") { session.status == .signedOut }
        XCTAssertNil(session.unavailableMessage)
        XCTAssertEqual(probes.requests.withLock { $0.count }, 1, "a connected server is not probed")
    }

    func testACapacityRefusalKeepsRetryingAndHonoursItsRetryAfter() async throws {
        failUpgrade(status: 429)
        probes.queue(429, retryAfter: "7", body: #"{"error":"Too many connections"}"#)
        session.start()
        await eventually("delay") { clock.recorded.count == 1 }
        XCTAssertEqual(session.unavailableMessage, "Too many connections")
        XCTAssertEqual(clock.recorded, [.seconds(7)])
        XCTAssertEqual(session.status, .reconnecting(attempt: 1, delay: .seconds(7)))
    }

    func testAnAvailableServerFallsBackToBackoffWithoutAMessage() async throws {
        failUpgrade()
        probes.queue(200, body: #"{"available":true}"#)
        session.start()
        await eventually("delay") { clock.recorded.count == 1 }
        XCTAssertNil(session.unavailableMessage)
        XCTAssertEqual(clock.recorded, [.seconds(1)])
        XCTAssertEqual(probes.requests.withLock { $0.count }, 1)
    }

    func testAReplyWithoutTheHeaderIsIgnored() async throws {
        failUpgrade(status: 503)
        probes.queue(503, header: false, retryAfter: "120", body: #"{"error":"Bad gateway from an edge"}"#)
        session.start()
        await eventually("delay") { clock.recorded.count == 1 }
        XCTAssertNil(session.unavailableMessage)
        XCTAssertEqual(clock.recorded, [.seconds(1)])
    }

    func testARefusedOriginStopsWithTheServersReason() async throws {
        failUpgrade(status: 403)
        probes.queue(403, body: #"{"error":"Origin not allowed"}"#)
        session.start()
        await eventually("stopped") { session.status == .stopped(.rejected(status: 403)) }
        XCTAssertEqual(session.unavailableMessage, "Origin not allowed")
    }

    func testEachFailedAttemptProbesOnce() async throws {
        failUpgrade()
        failUpgrade()
        session.start()
        await eventually("first delay") { clock.recorded.count == 1 }
        clock.release()
        await eventually("second delay") { clock.recorded.count == 2 }
        XCTAssertEqual(probes.requests.withLock { $0.count }, 2)
    }

    func testProbeURLAndReportParsing() throws {
        XCTAssertEqual(Connection.probeURL(for: URL(string: "wss://server.apron.chat/")!)?.absoluteString, "https://server.apron.chat/?apron_connection_status=1")
        XCTAssertEqual(Connection.probeURL(for: URL(string: "ws://localhost:8080/ws?x=1")!)?.absoluteString, "http://localhost:8080/ws?x=1&apron_connection_status=1")
        let report = Connection.report(from: ProbeResponse(status: 503, headers: ["apron-connection-status": "1"], body: Data(#"{"error":"Demo temporarily unavailable"}"#.utf8)))
        XCTAssertEqual(report, ConnectionStatusReport(message: "Demo temporarily unavailable", retryAfter: nil))
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

    func testAThreadsReplyCountSaysWhenOlderRepliesAreStillToLoad() async throws {
        session.start()
        let socket = await transport(0)
        try await signInAsGuest(on: socket)
        await socket.deliver(["method": "room_update", "params": ["joined": [["room_id": "t", "log_id": "100", "parent_room_id": "general"]]]])
        await eventually("thread known") { session.store.room("t") != nil }
        XCTAssertNil(session.replyWords(in: "t"), "nothing until its history loads")
        let open = Task { try await session.open("t") }
        _ = await frame(socket, 2)
        await socket.deliver(["id": "c3", "result": [
            "messages": [message("104", "d", room: "t")], "first_log_id": "104", "last_log_id": "104", "more": true, "latest_log_id": "104",
        ]])
        try await open.value
        XCTAssertEqual(session.replyWords(in: "t"), "1+ replies")
        XCTAssertEqual(session.title(of: "t"), "Untitled")
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
        let threads = await frame(socket, 3)
        XCTAssertEqual(threads, #"{"id":"c4","method":"room_list","params":{"filter":"not_joined","parent_room_id":"general"}}"#)
        await socket.deliver(["id": "c4", "result": ["not_joined": []]])
        try await open.value
        XCTAssertEqual(session.canLoadOlder("general"), true)

        let older = Task { try await session.loadOlder("general") }
        let olderFrame = await frame(socket, 4)
        XCTAssertEqual(olderFrame, #"{"id":"c5","method":"history","params":{"before":"103","limit":3,"room_id":"general"}}"#)
        await socket.deliver(["id": "c5", "result": [
            "messages": [message("101", "a"), message("102", "b"), message("103", "c")],
            "first_log_id": "101", "last_log_id": "103", "more": false, "latest_log_id": "106", "history_log_id": "101",
        ]])
        try await older.value
        XCTAssertEqual(session.canLoadOlder("general"), false)
        try await session.loadOlder("general")
        let sentCount = await socket.sentLog.count
        XCTAssertEqual(sentCount, 5, "no request past the start")
        XCTAssertEqual(session.timeline("general").map(\.messageID.text), ["101", "102", "103", "104", "105", "106"])
    }

    /// Opens general with 104–106 as the newest page, `more` true, history from `floor`.
    private func openGeneral(on socket: FakeTransport, floor: String = "101") async throws {
        let open = Task { try await session.open("general") }
        _ = await frame(socket, 2)
        await socket.deliver(["id": "c3", "result": [
            "messages": [message("104", "d"), message("105", "e"), message("106", "f")],
            "first_log_id": "104", "last_log_id": "106", "more": true, "latest_log_id": "106", "history_log_id": .string(floor),
        ]])
        _ = await frame(socket, 3)
        await socket.deliver(["id": "c4", "result": ["not_joined": []]])
        try await open.value
    }

    func testLandingPagesBackToWhereYouReadAndOpensAtTheNewLine() async throws {
        session.start()
        let socket = await transport(0)
        try await signInAsGuest(on: socket)
        try await openGeneral(on: socket, floor: "90")
        let land = Task { await session.landAtDivider("general", after: LogID("101")) }
        let older = await frame(socket, 4)
        XCTAssertEqual(older, #"{"id":"c5","method":"history","params":{"before":"103","limit":3,"room_id":"general"}}"#)
        await socket.deliver(["id": "c5", "result": [
            "messages": [message("101", "a"), message("102", "b"), message("103", "c")],
            "first_log_id": "101", "last_log_id": "103", "more": true, "latest_log_id": "106", "history_log_id": "90",
        ]])
        let target = await land.value
        XCTAssertEqual(target, LogID("102"), "the first message after where you read")
        let sent = await socket.sentLog.count
        XCTAssertEqual(sent, 5, "no page once the oldest loaded is where you read")
        let loaded = await session.landAtDivider("general", after: LogID("104"))
        XCTAssertEqual(loaded, LogID("105"), "already loaded: no request")
        let nothingRead = await session.landAtDivider("general", after: nil)
        XCTAssertNil(nothingRead, "nothing known read: the latest")
        let sentAfter = await socket.sentLog.count
        XCTAssertEqual(sentAfter, 5)
    }

    func testLandingStopsAfterThreePagesAndStaysAtTheLatest() async throws {
        session.start()
        let socket = await transport(0)
        try await signInAsGuest(on: socket)
        try await openGeneral(on: socket, floor: "40")
        let land = Task { await session.landAtDivider("general", after: LogID("50")) }
        let pages = [(before: "103", ids: ["103"]), (before: "102", ids: ["102"]), (before: "101", ids: ["101"])]
        for (index, page) in pages.enumerated() {
            let sent = await frame(socket, 4 + index)
            XCTAssertEqual(sent, #"{"id":"c\#(5 + index)","method":"history","params":{"before":"\#(page.before)","limit":3,"room_id":"general"}}"#)
            await socket.deliver(["id": .string("c\(5 + index)"), "result": [
                "messages": .array(page.ids.map { message($0, $0) }),
                "first_log_id": .string(page.ids[0]), "last_log_id": .string(page.ids.last!), "more": true, "latest_log_id": "106", "history_log_id": "40",
            ]])
        }
        let target = await land.value
        XCTAssertNil(target, "the line is further back than three pages")
        let sent = await socket.sentLog.count
        XCTAssertEqual(sent, 7, "three pages, no fourth")
        XCTAssertEqual(session.timeline("general").first?.messageID, LogID("101"))
        XCTAssertTrue(session.canLoadOlder("general"), "older pages are still there to scroll to")
    }

    func testLandingPagesNothingOnceTheTimelineMoved() async throws {
        session.start()
        let socket = await transport(0)
        try await signInAsGuest(on: socket)
        try await openGeneral(on: socket, floor: "90")
        let target = await session.landAtDivider("general", after: LogID("101"), still: { false })
        XCTAssertNil(target)
        let sent = await socket.sentLog.count
        XCTAssertEqual(sent, 4)
    }

    func testRevealWaitsForTheOpeningPageThenPagesBackToTheMessage() async throws {
        session.start()
        let socket = await transport(0)
        try await signInAsGuest(on: socket)
        let open = Task { try await session.open("general") }
        _ = await frame(socket, 2)
        let reveal = Task { try await session.reveal(LogID("101")!, in: "general") }
        await socket.deliver(["id": "c3", "result": [
            "messages": [message("104", "d"), message("105", "e"), message("106", "f")],
            "first_log_id": "104", "last_log_id": "106", "more": true, "latest_log_id": "106", "history_log_id": "90",
        ]])
        _ = await frame(socket, 3)
        await socket.deliver(["id": "c4", "result": ["not_joined": []]])
        try await open.value
        let older = await frame(socket, 4)
        XCTAssertEqual(older, #"{"id":"c5","method":"history","params":{"before":"103","limit":200,"room_id":"general"}}"#)
        await socket.deliver(["id": "c5", "result": [
            "messages": [message("101", "a"), message("102", "b"), message("103", "c")],
            "first_log_id": "101", "last_log_id": "103", "more": true, "latest_log_id": "106", "history_log_id": "90",
        ]])
        let shown = try await reveal.value
        XCTAssertTrue(shown)
        XCTAssertEqual(session.timeline("general").map(\.messageID.text), ["101", "102", "103", "104", "105", "106"])
        XCTAssertEqual(session.histories["general"]?.olderBefore, LogID("100"), "paging goes on from the revealed page")
    }

    func testRevealStopsOnceHistoryReachesPastAMissingMessage() async throws {
        session.start()
        let socket = await transport(0)
        try await signInAsGuest(on: socket)
        try await openGeneral(on: socket, floor: "90")
        let reveal = Task { try await session.reveal(LogID("102")!, in: "general") }
        _ = await frame(socket, 4)
        await socket.deliver(["id": "c5", "result": [
            "messages": [message("101", "a"), message("103", "c")],
            "first_log_id": "101", "last_log_id": "103", "more": true, "latest_log_id": "106", "history_log_id": "90",
        ]])
        let shown = try await reveal.value
        XCTAssertFalse(shown)
        let sent = await socket.sentLog.count
        XCTAssertEqual(sent, 5, "no page older than the message")
        XCTAssertEqual(session.canLoadOlder("general"), true, "the room still pages back on scroll")
    }

    func testRevealAsksNothingBelowTheRetentionFloor() async throws {
        session.start()
        let socket = await transport(0)
        try await signInAsGuest(on: socket)
        try await openGeneral(on: socket, floor: "104")
        let shown = try await session.reveal(LogID("101")!, in: "general")
        XCTAssertFalse(shown)
        let sent = await socket.sentLog.count
        XCTAssertEqual(sent, 4, "expired history is not asked for")
        let loaded = try await session.reveal(LogID("105")!, in: "general")
        XCTAssertTrue(loaded, "a loaded message needs no request")
    }

    func testOpeningAThreadListsNoThreadsOfIt() async throws {
        session.start()
        let socket = await transport(0)
        await eventually("signed out") { session.status == .signedOut }
        let signIn = Task { try await session.signIn(.guest(name: nil)) }
        _ = await frames(socket, count: 2)
        await socket.deliver(["id": "c1", "result": ["you": ["user_id": "ada", "name": "Ada"]]])
        await socket.deliver(["id": "c2", "result": ["joined": [
            ["room_id": "general", "log_id": "100", "latest_log_id": "100", "history_log_id": "100"],
            ["room_id": "130", "log_id": "130", "parent_room_id": "general", "latest_log_id": "130", "history_log_id": "130"],
        ]]])
        _ = try await signIn.value

        let open = Task { try await session.open("130") }
        _ = await frame(socket, 2)
        await socket.deliver(["id": "c3", "result": ["messages": [], "more": false, "latest_log_id": "130", "history_log_id": "130"]])
        try await open.value
        let sent = await socket.sentLog.count
        XCTAssertEqual(sent, 3, "history alone")
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
        _ = await frame(firstSocket, 3)
        await firstSocket.deliver(["id": "c4", "result": ["not_joined": []]])
        try await open.value
        await firstSocket.deliver(["method": "message", "params": message("107", "live")])
        await eventually("live message") { session.timeline("general").count == 2 }
        await firstSocket.dropFromServer()
        await eventually("backoff") { clock.recorded.count == 1 }
        clock.release()

        let second = await transport(1)
        _ = await frames(second, count: 2)
        await second.deliver(["id": "c5", "result": ["you": ["user_id": "ada", "name": "Ada"]]])
        await second.deliver(["id": "c6", "result": ["joined": [["room_id": "general", "log_id": "100", "latest_log_id": "109", "history_log_id": "101"]]]])
        let catchUp = await frame(second, 2)
        XCTAssertEqual(catchUp, #"{"id":"c7","method":"history","params":{"after":"108","limit":200,"room_id":"general"}}"#)
        await second.deliver(["id": "c7", "result": [
            "messages": [message("109", "missed")], "first_log_id": "109", "last_log_id": "109", "more": false,
            "latest_log_id": "109", "history_log_id": "101",
        ]])
        let threads = await frame(second, 3)
        XCTAssertEqual(threads, #"{"id":"c8","method":"room_list","params":{"filter":"not_joined","parent_room_id":"general"}}"#)
        await second.deliver(["id": "c8", "result": ["not_joined": [
            ["room_id": "108", "log_id": "108", "parent_room_id": "general", "title": "Missed", "latest_log_id": "108", "history_log_id": "108"],
        ]]])
        await eventually("caught up") { session.roomTree == [RoomNode(roomID: "general", threadIDs: ["108"])] }
        XCTAssertEqual(session.timeline("general").map(\.messageID.text), ["104", "107", "109"])
        XCTAssertEqual(session.joinedRoomIDs, ["general"])
    }

    /// General (on screen, its checkpoint 106) and 130 opened, then the connection dropped and a
    /// new one signed in, its joined listing giving each room's head.
    private func reconnectWithTwoRoomsOpen(heads: (general: String, other: String)) async throws -> FakeTransport {
        let firstSocket = FakeTransport()
        await firstSocket.deliver(Self.greeting)
        transports.queued.withLock { $0 = [firstSocket] }
        session.start()
        try await signInAsGuest(on: firstSocket)
        try await openGeneral(on: firstSocket)
        let open = Task { try await session.open("130") }
        _ = await frame(firstSocket, 4)
        await firstSocket.deliver(["id": "c5", "result": ["messages": [], "more": false, "latest_log_id": "130", "history_log_id": "130"]])
        _ = await frame(firstSocket, 5)
        await firstSocket.deliver(["id": "c6", "result": ["not_joined": []]])
        try await open.value
        session.show("general", true)
        XCTAssertFalse(session.isCatchingUp("general"), "opened on this connection")
        await firstSocket.dropFromServer()
        await eventually("backoff") { clock.recorded.count == 1 }
        XCTAssertFalse(session.isCatchingUp("general"), "not while reconnecting")
        XCTAssertTrue(session.reconnectingQuietly)
        clock.release()

        let second = await transport(1)
        _ = await frames(second, count: 2)
        await second.deliver(["id": "c7", "result": ["you": ["user_id": "ada", "name": "Ada"]]])
        await second.deliver(["id": "c8", "result": ["joined": [
            ["room_id": "general", "log_id": "100", "latest_log_id": .string(heads.general), "history_log_id": "101"],
            ["room_id": "130", "log_id": "130", "latest_log_id": .string(heads.other), "history_log_id": "130"],
        ]]])
        return second
    }

    func testAReconnectCatchesUpTheRoomOnScreenFirst() async throws {
        let second = try await reconnectWithTwoRoomsOpen(heads: ("108", "130"))
        let first = await frame(second, 2)
        XCTAssertEqual(first, #"{"id":"c9","method":"history","params":{"after":"107","limit":200,"room_id":"general"}}"#,
                       "general is on screen, so it goes first")
    }

    func testEachOpenedRoomCatchesUpUntilItsCatchUpIsDoneAndOneWithNothingNewAsksNothing() async throws {
        let second = try await reconnectWithTwoRoomsOpen(heads: ("108", "130"))
        _ = await frame(second, 2)
        XCTAssertFalse(session.reconnectingQuietly)
        XCTAssertEqual([session.isCatchingUp("general"), session.isCatchingUp("130")], [true, false],
                       "130's listed head is its checkpoint: nothing to ask for")
        await second.deliver(["id": "c9", "result": ["messages": [message("108", "g")], "first_log_id": "108", "last_log_id": "108",
                                                      "more": false, "latest_log_id": "108", "history_log_id": "101"]])
        let threads = await frame(second, 3)
        XCTAssertEqual(threads, #"{"id":"c10","method":"room_list","params":{"filter":"not_joined","parent_room_id":"general"}}"#)
        XCTAssertEqual([session.isCatchingUp("general"), session.isCatchingUp("130")], [false, false])
        await second.deliver(["id": "c10", "result": ["not_joined": []]])
        let all = await frames(second, count: 5)
        XCTAssertEqual(all.count, 5, "and 130's thread listing")
        XCTAssertFalse(all.contains { $0.contains(#""room_id":"130""#) && $0.contains("history") })
    }

    func testRoomsThatMovedOnCatchUpTogetherWithOneHistoryWithoutARoom() async throws {
        let second = try await reconnectWithTwoRoomsOpen(heads: ("108", "131"))
        let together = await frame(second, 2)
        XCTAssertEqual(together, #"{"id":"c9","method":"history","params":{"after":"107","limit":200}}"#,
                       "from the older checkpoint, every joined room's log as one")
        await second.deliver(["id": "c9", "result": [
            "messages": [message("108", "g"), message("131", "late", room: "130")], "first_log_id": "108", "last_log_id": "131",
            "more": false, "latest_log_id": "131", "history_log_id": "100",
        ]])
        let threads = await frame(second, 3)
        XCTAssertEqual(threads, #"{"id":"c10","method":"room_list","params":{"filter":"not_joined","parent_room_id":"general"}}"#)
        XCTAssertEqual(session.timeline("general").map(\.messageID.text), ["104", "105", "106", "108"])
        XCTAssertEqual(session.timeline("130").map(\.messageID.text), ["131"])
        XCTAssertEqual([session.isCatchingUp("general"), session.isCatchingUp("130")], [false, false])
    }

    func testAServerWithoutHistoryAcrossRoomsCatchesUpEachRoomAndIsNotAskedAgain() async throws {
        let second = try await reconnectWithTwoRoomsOpen(heads: ("108", "131"))
        _ = await frame(second, 2)
        await second.deliver(["id": "c9", "error": ["code": -32601, "message": "Unsupported"]])
        let general = await frame(second, 3)
        XCTAssertEqual(general, #"{"id":"c10","method":"history","params":{"after":"107","limit":200,"room_id":"general"}}"#)
        await second.deliver(["id": "c10", "result": ["messages": [], "more": false, "latest_log_id": "108", "history_log_id": "101"]])
        _ = await frame(second, 4)
        await second.deliver(["id": "c11", "result": ["not_joined": []]])
        let other = await frame(second, 5)
        XCTAssertEqual(other, #"{"id":"c12","method":"history","params":{"after":"131","limit":200,"room_id":"130"}}"#)
        await second.deliver(["id": "c12", "result": ["messages": [], "more": false, "latest_log_id": "131", "history_log_id": "130"]])
        await eventually("caught up") { !session.isCatchingUp("130") }

        await second.dropFromServer()
        await eventually("backoff") { clock.recorded.count == 2 }
        clock.release()
        let third = await transport(2)
        _ = await frames(third, count: 2)
        await third.deliver(["id": "c14", "result": ["you": ["user_id": "ada", "name": "Ada"]]])
        await third.deliver(["id": "c15", "result": ["joined": [
            ["room_id": "general", "log_id": "100", "latest_log_id": "109", "history_log_id": "101"],
            ["room_id": "130", "log_id": "130", "latest_log_id": "132", "history_log_id": "130"],
        ]]])
        let again = await frame(third, 2)
        XCTAssertEqual(again, #"{"id":"c16","method":"history","params":{"after":"109","limit":200,"room_id":"general"}}"#,
                       "not asked across rooms again")
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

    /// Signs in on a server that shows read receipts, joined to `general` and the private room `p1` with Bob.
    private func signInWithReceipts() async throws -> FakeTransport {
        let socket = queueTransport(capabilities: ["history", "rooms", "activity", "ext:settings"], ext: ["settings": ["read_receipts": "private"]])
        session.start()
        await eventually("signed out") { session.status == .signedOut }
        let signIn = Task { try await session.signIn(.guest(name: nil)) }
        _ = await frames(socket, count: 2)
        await socket.deliver(["id": "c1", "result": ["you": ["user_id": "ada", "name": "Ada"], "token": "t1"]])
        await socket.deliver(["id": "c2", "result": ["joined": [
            ["room_id": "general", "log_id": "100", "title": "General", "latest_log_id": "100", "history_log_id": "100"],
            ["room_id": "p1", "log_id": "110", "private": true, "latest_log_id": "110", "history_log_id": "110",
             "members": [["user_id": "ada", "name": "Ada"], ["user_id": "bob", "name": "Bob"]]],
        ]]])
        _ = try await signIn.value
        return socket
    }

    func testReadReceiptsPlaceEachOtherMemberUnderTheNewestMessageTheyReadInAPrivateRoom() async throws {
        let socket = try await signInWithReceipts()
        for (id, from) in [("201", "bob"), ("202", "ada"), ("203", "~room"), ("204", "ada")] {
            await socket.deliver(["method": "message", "params": ["message_id": .string(id), "log_id": .string(id), "room_id": "p1",
                                                                   "from": ["user_id": .string(from)], "body": ["text": "hi"]]])
        }
        await socket.deliver(["method": "message", "params": message("205", "x")])
        func read(_ from: JSONValue, _ room: String, _ id: String) -> JSONValue {
            ["method": "activity", "params": ["room_id": .string(room), "from": from, "read_message_id": .string(id)]]
        }
        await socket.deliver(read(["user_id": "bob", "name": "Bob"], "p1", "203"))
        await socket.deliver(read(["user_id": "carol"], "p1", "204"))
        await socket.deliver(read(["user_id": "bob"], "general", "205"))
        await socket.deliver(read(["user_id": "bob"], "p1", "150"))
        await eventually("cursors applied") { session.readers["p1"]?["carol"] != nil && session.readers["general"] != nil }
        XCTAssertEqual(session.readers["p1"], ["bob": LogID("203")!, "carol": LogID("204")!], "a cursor only moves forward")
        let placed = session.receipts(in: "p1", shown: session.timeline("p1"))
        XCTAssertEqual(placed.mapValues { $0.map(\.name) }, [LogID("202")!: ["Bob"]],
                       "under the newest message read through that is not a system one; Carol is no member")
        XCTAssertEqual(session.receipts(in: "general", shown: session.timeline("general")), [:], "none in a public room")
        XCTAssertEqual(SeenBy.words(["Bob"]), "Seen by Bob")
        XCTAssertEqual(SeenBy.words(["Bob", "Carol", "Dev"]), "Seen by Bob, Carol and Dev")
        XCTAssertEqual(SeenBy.words(["Bob", "Carol", "Dev", "Eve", "Fay"]), "Seen by Bob, Carol, Dev and 2 more")
        session.receiptSettings.set(false)
        XCTAssertEqual(session.receipts(in: "p1", shown: session.timeline("p1")), [:], "off, nobody's show")
    }

    func testWithReadReceiptsOffYourCursorInAPrivateRoomStaysHereUntilTheyComeBackOn() async throws {
        let socket = try await signInWithReceipts()
        XCTAssertTrue(session.offersReadReceipts)
        session.receiptSettings.set(false)
        await session.markRead("p1", through: LogID("120")!)
        await session.markRead("general", through: LogID("130")!)
        _ = await frames(socket, count: 3)
        XCTAssertEqual(session.readCursors["p1"], LogID("120"), "the cursor still moves here")
        session.receiptSettings.set(true)
        await session.readReceiptsTurnedOn()
        await session.readReceiptsTurnedOn()
        let sent = await frames(socket, count: 4)
        XCTAssertEqual(Array(sent[2...]), [
            #"{"method":"activity","params":{"read_message_id":"130","room_id":"general"}}"#,
            #"{"method":"activity","params":{"read_message_id":"120","room_id":"p1"}}"#,
        ], "public rooms keep syncing; back on, only the cursor that moved goes, once")
        try await Task.sleep(for: .milliseconds(50))
        let all = await socket.sentLog
        XCTAssertEqual(all.count, 4)
    }

    func testReadCursorsAreThrottledToTheNewestOncePerInterval() async throws {
        let socket = queueTransport(capabilities: ["history", "rooms", "activity"])
        session.start()
        try await signInAsGuest(on: socket)
        let marks = (201 ... 210).map { id in Task { await session.markRead("general", through: LogID(String(id))!) } }
        for mark in marks { await mark.value }
        let sent = await frames(socket, count: 4)
        try await Task.sleep(for: .milliseconds(250))
        let all = await socket.sentLog
        XCTAssertEqual(Array(all[2...]), [
            #"{"method":"activity","params":{"read_message_id":"201","room_id":"general"}}"#,
            #"{"method":"activity","params":{"read_message_id":"210","room_id":"general"}}"#,
        ])
        XCTAssertEqual(sent.count, 4)
        XCTAssertEqual(session.readPositions, ["general": LogID("210")!])
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
        _ = await frame(socket, 3)
        await socket.deliver(["id": "c4", "result": ["not_joined": []]])
        try await open.value
        XCTAssertEqual(session.timeline("general").map(\.messageID.text), ["130"])
        XCTAssertEqual(session.newLine(in: "general", after: LogID("125")!), LogID("130"), "the loaded tombstone at 120 shows nothing unread is older")

        let older = Task { try await session.loadOlder("general") }
        _ = await frame(socket, 4)
        await socket.deliver(["id": "c5", "result": [
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

        try await expect(#"{"id":"c3","method":"message","params":{"body":{"format":"markdown","text":"hi"},"reply_to":{"message_id":"200"},"room_id":"general"}}"#,
                         reply: ["message_id": "201"]) { try await self.session.send("hi", in: "general", replyTo: LogID("200")) }
        try await expect(#"{"id":"c4","method":"message","params":{"body":{"format":"markdown","mentions":["bob"],"text":"hello"},"message_id":"200","reply_to":{"message_id":"150"},"room_id":"general"}}"#) {
            try await self.session.edit(MessageEdit(original), text: "hello", mentions: ["bob"])
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
        try await expect(#"{"id":"c12","method":"message","params":{"body":{"format":"markdown","mentions":["bob"],"text":"helo"},"message_id":"200","room_id":"general"}}"#) {
            try await self.session.removeReply(from: original)
        }
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
        let edit = Task { try await session.edit(MessageEdit(original), text: "hello", mentions: []) }
        let sent = await frame(socket, 2)
        XCTAssertEqual(sent, #"{"id":"c3","method":"message","params":{"body":{"text":"hello"},"ext":{"k":1},"message_id":"200","reply_to":{"message_id":"150"},"room_id":"general"}}"#)
        await socket.deliver(["id": "c3", "result": [:]])
        try await edit.value
    }

    func testAnEditSavesWhoItsTextStillMentions() async throws {
        let socket = try await signInWithRooms(["user_id": "mia"], capabilities: ["history", "edit", "rooms"])
        await socket.deliver(["method": "message", "params": [
            "message_id": "200", "log_id": "200", "room_id": "general", "from": ["user_id": "mia"],
            "body": ["text": "@guest_1234 and @bob, look", "format": "markdown", "mentions": ["guest_1234", "bob"]],
        ]])
        await eventually("message installed") { session.store.message(LogID("200")!) != nil }
        var field = DraftField(editing: try XCTUnwrap(session.store.message(LogID("200")!)), in: session)
        XCTAssertEqual(field.mentions, ["guest_1234": "guest_1234", "bob": "bob"], "an @user_id in the text keeps its mention")
        field.text = "@guest_1234 look, and @ad"
        field.insert(mention: "ada", named: "Ada")
        let edit = Task { try await session.submit(ComposerDraft(field: field), in: "general") }
        let sent = await frame(socket, 2)
        XCTAssertEqual(sent, #"{"id":"c3","method":"message","params":{"body":{"format":"markdown","mentions":["guest_1234","ada"],"text":"@guest_1234 look, and @Ada"},"message_id":"200","room_id":"general"}}"#,
                       "Bob's @ is gone and Ada is picked, in the order the text names them")
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
        XCTAssertEqual(session.permissions, Permissions.core)
        XCTAssertTrue(session.permissions.addMembers, "PROTOCOL.md lets any member ask to add others")
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
        XCTAssertEqual(sent1, #"{"id":"c3","method":"message","params":{"body":{"format":"markdown","mentions":["bob"],"text":"hi @Bob"},"room_id":"general"}}"#)
        await socket.deliver(["id": "c3", "result": ["message_id": "300"]])
        let posted = try await mention.value
        XCTAssertEqual(posted, LogID("300"))
        let command = Task { try await session.send("/help", in: "general") }
        let sent2 = await frame(socket, 3)
        XCTAssertEqual(sent2, #"{"id":"c4","method":"command","params":{"body":{"format":"markdown","text":"/help"},"room_id":"general"}}"#)
        await socket.deliver(["id": "c4", "result": [:]])
        let ran = try await command.value
        XCTAssertNil(ran)
        let slash = Task { try await session.send("//shrug", in: "general") }
        let sent3 = await frame(socket, 4)
        XCTAssertEqual(sent3, #"{"id":"c5","method":"message","params":{"body":{"format":"markdown","text":"/shrug"},"room_id":"general"}}"#)
        await socket.deliver(["id": "c5", "result": ["message_id": "301"]])
        _ = try await slash.value
    }

    private func privateNotice(_ text: String, in roomID: String = "general") -> JSONValue {
        ["method": "message", "params": ["room_id": .string(roomID), "from": ["user_id": "~private", "name": "System message to you"],
                                         "body": ["text": .string(text), "format": "markdown"]]]
    }

    func testCommandsComeFromOneHiddenHelpPerConnectionAndRoles() async throws {
        session.start()
        let socket = await transport(0)
        try await signInAsGuest(on: socket)

        let loading = Task { await session.loadCommands(in: "general") }
        let asked = await frame(socket, 2)
        XCTAssertEqual(asked, #"{"id":"c3","method":"command","params":{"body":{"format":"plain","text":"/help"},"room_id":"general"}}"#)
        await session.loadCommands(in: "general")
        await socket.deliver(privateNotice(CommandHelpTests.guest))
        await socket.deliver(["id": "c3", "result": [:]])
        await loading.value
        await eventually("commands listed") { session.commands != nil }
        XCTAssertEqual(session.commands?.commands.map(\.usage), ["/help"])
        XCTAssertEqual(session.notices.count, 0)

        await session.loadCommands(in: "general")
        let typed = Task { try await session.send("/help", in: "general") }
        let sentByHand = await frame(socket, 3)
        XCTAssertEqual(sentByHand, #"{"id":"c4","method":"command","params":{"body":{"format":"markdown","text":"/help"},"room_id":"general"}}"#)
        await socket.deliver(privateNotice(CommandHelpTests.guest))
        await socket.deliver(["id": "c4", "result": [:]])
        _ = try await typed.value
        await socket.deliver(privateNotice("Slow down: you can send 5 messages a minute here."))
        await eventually("both notices shown") { session.notices.count == 2 }
        XCTAssertEqual(session.notices.map { $0.body?["text"]?.stringValue }, [CommandHelpTests.guest, "Slow down: you can send 5 messages a minute here."])

        await socket.deliver(["method": "user", "params": ["you": ["user_id": "ada", "name": "Ada", "roles": ["admin"]]]])
        await eventually("admin role") { session.you?.roles == ["admin"] }
        let reloading = Task { await session.loadCommands(in: "general") }
        let askedAgain = await frame(socket, 4)
        XCTAssertEqual(askedAgain, #"{"id":"c5","method":"command","params":{"body":{"format":"plain","text":"/help"},"room_id":"general"}}"#)
        await socket.deliver(privateNotice(CommandHelpTests.cloudflareAdmin))
        await socket.deliver(["id": "c5", "result": [:]])
        await reloading.value
        await eventually("admin commands") { session.commands?.commands.count == 17 }
        XCTAssertEqual(session.notices.count, 2)

        let second = queueTransport(capabilities: ["history", "edit", "rooms", "reactions"])
        await socket.dropFromServer()
        await eventually("backoff") { clock.recorded.count == 1 }
        clock.release()
        _ = await frames(second, count: 2)
        await second.deliver(["id": "c6", "result": ["you": ["user_id": "ada", "name": "Ada", "roles": ["admin"]]]])
        await eventually("signed in again") { session.status == .signedIn }
        XCTAssertEqual(session.commands?.commands.count, 17)
        let afterReconnect = Task { await session.loadCommands(in: "general") }
        let askedOnReconnect = await frame(second, 2)
        XCTAssertEqual(askedOnReconnect, #"{"id":"c8","method":"command","params":{"body":{"format":"plain","text":"/help"},"room_id":"general"}}"#)
        await second.deliver(["id": "c8", "error": ["code": -32000, "message": "Slow down"]])
        await afterReconnect.value
        await session.loadCommands(in: "general")
        await second.deliver(privateNotice(CommandHelpTests.guest))
        await eventually("an unasked list shows") { session.notices.count == 3 }
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

        let resent = #"{"id":"q-c3","method":"message","params":{"body":{"format":"markdown","text":"queued"},"room_id":"general"}}"#
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

    func testYouWithANewUserIDIsTheAccountRenamedAndEverythingKeptFollowsIt() async throws {
        session.start()
        let socket = await transport(0)
        var saved: [ServerRecord.Account?] = []
        session.onRecordChange = { saved.append($0.account) }
        try await signInAsGuest(on: socket, you: ["user_id": "ada", "name": "Ada", "avatar": "https://chat.example/a.png"])
        await socket.deliver(["method": "message", "params": ["message_id": "200", "log_id": "200", "room_id": "general", "from": ["user_id": "ada", "name": "Ada"], "body": ["text": "old"]]])
        await socket.deliver(["method": "message", "params": ["message_id": "201", "log_id": "201", "room_id": "general", "from": ["user_id": "bob", "name": "Bob"], "body": ["text": "hi"]]])
        await eventually("messages") { session.store.messages(in: "general").count == 2 }
        await session.markRead("general", through: LogID("201")!)
        session.post("in flight", in: "general")
        _ = await frame(socket, 2)

        await socket.deliver(["method": "user", "params": ["you": ["user_id": "lovelace", "name": "Ada L"]]])
        await eventually("renamed") { session.you?.userID == "lovelace" }

        XCTAssertEqual(session.you?.json["avatar"]?.stringValue, "https://chat.example/a.png", "the kept profile moves to the new id")
        XCTAssertEqual(session.you?.json["name"]?.stringValue, "Ada L")
        XCTAssertEqual(session.record.account, ServerRecord.Account(userID: "lovelace", name: "Ada", scheme: "guest"))
        XCTAssertEqual(saved.last??.userID, "lovelace")
        XCTAssertEqual(session.outbox.map(\.userID), ["lovelace"])
        XCTAssertEqual(session.outbox.first?.state, .sending, "the queue is not failed")
        XCTAssertEqual(positions.positions(server: record.id, user: "lovelace"), ["general": LogID("201")!])
        XCTAssertEqual(positions.positions(server: record.id, user: "ada"), [:])
        XCTAssertEqual(session.readPositions, ["general": LogID("201")!])
        XCTAssertEqual(session.users.user("ada")?["name"]?.stringValue, "Ada L", "the old id reads as the new one")
        XCTAssertTrue(session.isYou("ada"))
        XCTAssertFalse(session.isYou("bob"))
        XCTAssertEqual(session.unreadCount(in: "general"), 0, "the old id's messages are still yours")

        await socket.deliver(["id": "q-c3", "result": ["message_id": "300"]])
        await eventually("sent") { session.outbox.isEmpty }
    }

    func testANewWithOldIsAnotherAccountRenamedAndItsRecordsStillShowItsName() async throws {
        session.start()
        let socket = await transport(0)
        try await signInAsGuest(on: socket)
        await socket.deliver(["method": "user", "params": ["new": ["user_id": "bob", "name": "Bob", "avatar": "https://chat.example/b.png"]]])
        await socket.deliver(["method": "user", "params": ["new": ["user_id": "robert", "name": "Robert"], "old": ["user_id": "bob", "name": "Bob"]]])
        await eventually("renamed") { session.users.user("robert")?["name"]?.stringValue == "Robert" }

        XCTAssertEqual(session.users.user("robert")?["avatar"]?.stringValue, "https://chat.example/b.png")
        XCTAssertEqual(session.users.user("bob")?["user_id"]?.stringValue, "robert")
        XCTAssertEqual(session.displayName(for: UserObject(["user_id": "bob", "name": "Bob"])!), "Robert")
        XCTAssertEqual(session.you?.userID, "ada")
        XCTAssertFalse(session.isYou("bob"))
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

    func testAnUploadLimitHoldsBackOnlyTheMessageWithTheFile() async throws {
        let socket = queueTransport(capabilities: ["history", "edit", "rooms", "reactions", "ext:limits"])
        session.start()
        try await signInAsGuest(on: socket)
        let photo = Attachment(fileURL: URL(filePath: "/tmp/photo.png"), title: "photo.png", contentType: "image/png", byteCount: 10)
        session.post("look", in: "general", attachments: [photo])
        session.post("anyway", in: "general")
        _ = await frame(socket, 2)
        await socket.deliver(["id": "q-c3", "error": ["code": -32002, "message": "Daily upload limit reached",
                                                      "data": ["retry_after": 40_000, "ext": ["limits": "upload"]]]])
        let next = await frame(socket, 3)
        XCTAssertEqual(next, #"{"id":"q-c4","method":"message","params":{"body":{"format":"markdown","text":"anyway"},"room_id":"general"}}"#)
        XCTAssertEqual(session.outbox.first?.state, .failed("Daily upload limit reached"))
        XCTAssertEqual(clock.recorded, [])
    }

    func testAWriteLimitWaitsItsRetryAfterAndResendsWithTheSameID() async throws {
        session.start()
        let socket = await transport(0)
        try await signInAsGuest(on: socket)
        session.post("hello", in: "general")
        _ = await frame(socket, 2)
        await socket.deliver(["id": "q-c3", "error": ["code": -32002, "message": "Posting limit reached",
                                                      "data": ["retry_after": 3, "ext": ["limits": "write"]]]])
        await eventually("waiting") { clock.recorded == [.seconds(3)] }
        clock.release()
        let resent = await frame(socket, 3)
        XCTAssertEqual(resent, #"{"id":"q-c3","method":"message","params":{"body":{"format":"markdown","text":"hello"},"room_id":"general"}}"#)
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
        XCTAssertNil(TokenPayload(parsing: "apron:?server=wss://chat.example/ws&token=Hk41&state=q8Rz"), "an apron: URI carries no credential")
        XCTAssertNil(TokenPayload(parsing: "https://chat.example/#server=wss://chat.example/ws&token=inv_Qm7x"), "only link.apron.chat's form")
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
        XCTAssertNil(SignInFill("apron:?server=wss://chat.example/ws&token=Hk41", signingInTo: nil))
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
        XCTAssertEqual(users.displayName(for: UserObject(["user_id": "ada"])!), "\u{2068}Ada\u{2069} (@ada)")
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

// MARK: Typing (§4.6)

extension ServerSessionTests {
    private static let typing15 = #"{"method":"activity","params":{"room_id":"general","typing":15}}"#
    private static let typing0 = #"{"method":"activity","params":{"room_id":"general","typing":0}}"#

    func testTypingGoesOnceARefreshAndStopsWhenTheComposerIsLeftAlone() async throws {
        let socket = queueTransport(capabilities: ["history", "rooms", "activity"])
        session.start()
        try await signInAsGuest(on: socket)
        for _ in 0 ..< 9 {
            session.composerChanged(in: "general")
            try await Task.sleep(for: .milliseconds(50))
        }
        let sent = await frames(socket, count: 5)
        XCTAssertEqual(Array(sent[2...]), [Self.typing15, Self.typing15, Self.typing0],
                       "nine keystrokes over 450 ms: one frame, one refresh after 300 ms, then 0 after 150 ms idle")
        try await Task.sleep(for: .milliseconds(250))
        let all = await socket.sentLog
        XCTAssertEqual(all.count, 5, "nothing more once stopped")
    }

    func testAMessageEndsTypingWithoutAZero() async throws {
        let socket = queueTransport(capabilities: ["history", "rooms", "activity"])
        session.start()
        try await signInAsGuest(on: socket)
        session.composerChanged(in: "general")
        let posting = Task { try await session.send("hi", in: "general") }
        _ = await frames(socket, count: 4)
        await socket.deliver(["id": "c3", "result": ["message_id": "200"]])
        _ = try await posting.value
        try await Task.sleep(for: .milliseconds(300))
        let all = await socket.sentLog
        XCTAssertEqual(Array(all[2...]), [Self.typing15, #"{"id":"c3","method":"message","params":{"body":{"format":"markdown","text":"hi"},"room_id":"general"}}"#])
    }

    func testWithoutTheActivityCapabilityTypingSendsNothing() async throws {
        let socket = queueTransport(capabilities: ["history", "rooms"])
        session.start()
        try await signInAsGuest(on: socket)
        session.composerChanged(in: "general")
        try await Task.sleep(for: .milliseconds(250))
        let all = await socket.sentLog
        XCTAssertEqual(all.count, 2, "auth and room_list only: \(all)")
    }

    func testOthersShowAsTypingUntilTheirTimeAMessageOrZero() async throws {
        let socket = queueTransport(capabilities: ["history", "rooms", "activity"])
        session.start()
        try await signInAsGuest(on: socket)
        func typing(_ id: String, _ name: String, _ seconds: JSONValue) -> JSONValue {
            ["method": "activity", "params": ["room_id": "general", "from": ["user_id": .string(id), "name": .string(name)], "typing": seconds]]
        }
        await socket.deliver(typing("bob", "Bob", 15))
        await socket.deliver(typing("ada", "Ada", 15))
        await socket.deliver(typing("carol", "Carol", 15))
        await socket.deliver(typing("bob", "Bob", 15))
        await eventually("four frames applied") { session.typingNames(in: "general") == ["Carol", "Bob"] }
        XCTAssertEqual(TypingLine.line(session.typingNames(in: "general")), "\u{2068}Carol\u{2069} and \u{2068}Bob\u{2069} are typing…",
                       "you never show; a refresh moves Bob last")

        await socket.deliver(["method": "message", "params": ["message_id": "201", "log_id": "201", "room_id": "general",
                                                              "from": ["user_id": "carol"], "body": ["text": "done"]]])
        await eventually("Carol's message ends hers") { session.typingNames(in: "general") == ["Bob"] }
        await socket.deliver(typing("bob", "Bob", 0))
        await eventually("Bob stopped") { session.typingNames(in: "general").isEmpty }

        await socket.deliver(typing("dan", "Dan", 3600))
        await eventually("Dan shows") { session.typingNames(in: "general") == ["Dan"] }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(session.typingNames(in: "general"), [], "held no longer than `longest`, whatever was sent")
    }

    func testTypingLinesSayWhoAsTheWebDoes() {
        XCTAssertEqual([[], ["Ada"], ["Ada", "Bram"], ["Ada", "Bram", "Chiara"]].map(TypingLine.line),
                       [nil, "\u{2068}Ada\u{2069} is typing…", "\u{2068}Ada\u{2069} and \u{2068}Bram\u{2069} are typing…", "Several people are typing…"])
        XCTAssertEqual([[], ["Ada"], ["Ada", "Bram"], ["Ada", "Bram", "Chiara"]].map(TypingLine.subtitle),
                       [nil, "\u{2068}Ada\u{2069} is typing…", "2 people are typing…", "3 people are typing…"])
    }
}

// MARK: First show and the welcome

extension ServerSessionTests {
    private func roomlessNotice(_ text: String) -> JSONValue {
        ["method": "message", "params": ["from": ["user_id": "~private", "name": "Only you"], "body": ["text": .string(text)]]]
    }

    private func noticeTexts(in roomID: String) -> [String?] {
        session.notices(in: roomID).map { $0.body?["text"]?.stringValue }
    }

    /// Signs in as a guest the server gives no token, in two rooms listed Zoo first.
    private func signInAsTokenlessGuest(on socket: FakeTransport) async throws {
        await eventually("signed out") { session.status == .signedOut }
        let signIn = Task { try await session.signIn(.guest(name: nil)) }
        _ = await frames(socket, count: 2)
        await socket.deliver(["id": "c1", "result": ["you": ["user_id": "guest_1"]]])
        await socket.deliver(["id": "c2", "result": ["joined": [
            ["room_id": "zoo", "log_id": "100", "title": "Zoo", "latest_log_id": "100", "history_log_id": "100"],
            ["room_id": "atrium", "log_id": "101", "title": "Atrium", "latest_log_id": "101", "history_log_id": "101"],
        ]]])
        _ = try await signIn.value
    }

    func testTheWelcomeBeforeAuthShowsInTheFirstRoomAndTheNextConnectionsReplacesIt() async throws {
        session.start()
        let socket = await transport(0)
        await socket.deliver(roomlessNotice("Guests can read."))
        await socket.deliver(roomlessNotice("Guests can read. Sign in with passkey to post."))
        try await signInAsTokenlessGuest(on: socket)
        XCTAssertEqual(session.firstRoom, "atrium", "the rooms list's first, by title, not the listing's")
        XCTAssertEqual(noticeTexts(in: "atrium"), ["Guests can read. Sign in with passkey to post."], "a welcome replaces the one before")
        XCTAssertEqual(noticeTexts(in: "zoo"), [])
        XCTAssertEqual(session.notices.map(\.welcome), [true])

        session.show("zoo", true)
        await socket.deliver(roomlessNotice("Reminder: standup"))
        await eventually("the notice after sign-in") { session.notices.count == 2 }
        XCTAssertEqual(noticeTexts(in: "zoo"), ["Reminder: standup"], "after sign-in, a notice without a room shows in the one on screen")

        let second = queueTransport(capabilities: ["history", "edit", "rooms", "reactions"])
        await socket.dropFromServer()
        await eventually("backoff") { clock.recorded.count == 1 }
        clock.release()
        await eventually("connected again") { session.status == .signedOut }
        await second.deliver(roomlessNotice("Welcome back."))
        await eventually("the new welcome") { noticeTexts(in: "atrium") == ["Welcome back."] }
        XCTAssertEqual(noticeTexts(in: "zoo"), ["Reminder: standup"])
    }

    func testASignInThatGivesATokenDropsTheWelcome() async throws {
        session.start()
        let socket = await transport(0)
        await socket.deliver(roomlessNotice("Guests can read."))
        await eventually("the welcome") { session.notices.count == 1 }
        try await signInAsGuest(on: socket)
        XCTAssertEqual(session.notices, [], "a token of its own makes it a registered session, which the welcome no longer speaks to")
    }

    func testAFirstPageIsHeldUntilItsThreadListingComes() async throws {
        session.start()
        let socket = await transport(0)
        try await signInAsGuest(on: socket)
        let open = Task { try await session.open("general") }
        _ = await frame(socket, 2)
        XCTAssertEqual(session.held, ["general"])
        await socket.deliver(["id": "c3", "result": [
            "messages": [message("104", "d")], "first_log_id": "104", "last_log_id": "104", "more": false, "latest_log_id": "104",
        ]])
        _ = await frame(socket, 3)
        XCTAssertEqual(session.held, ["general"], "the page waits for the listing")
        await socket.deliver(["id": "c4", "result": ["not_joined": [
            ["room_id": "130", "log_id": "130", "parent_room_id": "general", "title": "Deploy", "latest_log_id": "130", "history_log_id": "130"],
        ]]])
        try await open.value
        XCTAssertEqual(session.held, [])
        XCTAssertEqual(session.timelineItems("general", lineBefore: nil).map(\.id).filter { !$0.hasPrefix("day-") }, ["104", "thread-130"],
                       "the thread card comes with the page")
        try await session.open("general")
        XCTAssertEqual(session.held, [], "shown again, it does not wait")
    }

    func testASlowThreadListingHoldsTheFirstPageForThreadsWaitAtMost() async throws {
        await session.stop()
        let counter = Mutex(0)
        let transports = transports, clock = clock
        session = ServerSession(record: record, tokens: tokens, positions: positions, environment: ServerSession.Environment(
            makeTransport: { _ in transports.next() },
            sleep: { try await clock.sleep($0) },
            jitter: { 1 },
            makeRequestID: { counter.withLock { $0 += 1; return "c\($0)" } },
            pageSize: 3,
            threadsWait: .milliseconds(50)
        ))
        session.start()
        let socket = await transport(0)
        try await signInAsGuest(on: socket)
        let open = Task { try await session.open("general") }
        _ = await frame(socket, 2)
        await socket.deliver(["id": "c3", "result": [
            "messages": [message("104", "d")], "first_log_id": "104", "last_log_id": "104", "more": false, "latest_log_id": "104",
        ]])
        try await open.value
        XCTAssertEqual(session.held, [], "shown once the wait is up, with no listing yet")
        await socket.deliver(["id": "c4", "result": ["not_joined": [
            ["room_id": "130", "log_id": "130", "parent_room_id": "general", "title": "Deploy", "latest_log_id": "130", "history_log_id": "130"],
        ]]])
        await eventually("the late listing") { session.store.room("130") != nil }
        XCTAssertEqual(session.timelineItems("general", lineBefore: nil).last?.id, "thread-130")
    }
}
