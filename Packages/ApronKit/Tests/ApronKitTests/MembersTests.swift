import Foundation
import Synchronization
import XCTest
@testable import ApronKit

/// Member management, as apron-web's MemberList: who may add and remove, Add people's picker,
/// Remove's question, each member's menu, and a server that doesn't support it.
@MainActor
final class MembersTests: XCTestCase {
    func testAddPeopleListsThoseNotInTheRoomOrTheUserIDTyped() async throws {
        let store = await PreviewFixtures.makeStore()
        let home = try XCTUnwrap(store.session(for: PreviewFixtures.homeID))
        var picker = PeoplePicker()
        XCTAssertEqual(home.addablePeople(picker, to: "ops").map(\.name), ["Ada Okafor", "Bram", "Chiara", "Eun-ji"], "Dev is in ops")
        picker.query = "@carol"
        XCTAssertEqual(home.addablePeople(picker, to: "ops"), [PickPerson(userID: "carol", name: "carol", existing: false, typed: true)])
        picker.query = "@dev"
        XCTAssertEqual(home.addablePeople(picker, to: "ops"), [], "a member is not offered by @user_id")
        picker.query = "Carol Smith"
        XCTAssertEqual(home.addablePeople(picker, to: "ops"), [], "a name is never taken as an ID")

        XCTAssertTrue(home.mayAddMembers(to: "ops"))
        XCTAssertEqual(home.memberMenu(for: "dev", in: "ops"), MemberMenu(directMessage: true, remove: true))
        XCTAssertTrue(home.memberMenu(for: "sam", in: "ops").isEmpty, "your own row has only your card")
        XCTAssertEqual(home.removeQuestion("dev", from: "ops"), "Remove Dev from ops?")
    }

    private let record = ServerRecord(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000a")!, url: URL(string: "wss://chat.example/ws")!)
    private var session: ServerSession!
    private var socket: FakeTransport!

    override func tearDown() async throws {
        await session?.stop()
    }

    /// Signed in as Ada with `you` and capabilities as given, in `general` with Bob and the private `p0`.
    private func signIn(you: JSONValue = ["user_id": "ada", "name": "Ada"], capabilities: [String] = ["history", "rooms"]) async throws {
        let tokens = InMemoryTokenStore()
        try tokens.setToken("t1", for: record.id)
        let counter = Mutex(0)
        let socket = FakeTransport()
        self.socket = socket
        session = ServerSession(record: record, tokens: tokens, environment: ServerSession.Environment(
            makeTransport: { _ in socket }, sleep: { _ in try await Task.sleep(for: .seconds(3600)) }, jitter: { 1 },
            makeRequestID: { counter.withLock { $0 += 1; return "c\($0)" } }))
        Task { await socket.deliver(["method": "server", "params": ["apron": 9, "auth": ["token"], "capabilities": .array(capabilities.map(JSONValue.string))]]) }
        session.start()
        await eventually("auth and room_list") { await socket.sentLog.count >= 2 }
        await socket.deliver(["id": "c1", "result": ["you": you]])
        await socket.deliver(["id": "c2", "result": ["joined": [
            ["room_id": "general", "log_id": "100", "title": "General", "members": [["user_id": "ada"], ["user_id": "bob"]]],
            ["room_id": "p0", "log_id": "101", "private": true, "members": [["user_id": "ada"]]],
        ]]])
        await eventually("signed in") { self.session.status == .signedIn && self.session.joinedRoomIDs.count == 2 }
    }

    private func expectSent(_ index: Int, _ expected: String, file: StaticString = #filePath, line: UInt = #line) async {
        await eventually("frame \(index)") { await self.socket.sentLog.count > index }
        let frame = await socket.sentLog[index]
        XCTAssertEqual(frame, expected, file: file, line: line)
    }

    func testAddMembersNeedsThePermissionOutsideAPrivateRoom() async throws {
        try await signIn(you: ["user_id": "ada", "ext": ["permissions": ["add_members": false]]], capabilities: ["history", "rooms", "ext:permissions"])
        XCTAssertFalse(session.mayAddMembers(to: "general"))
        XCTAssertTrue(session.mayAddMembers(to: "p0"), "a private room's members add people to it")
        XCTAssertTrue(session.memberMenu(for: "bob", in: "general").remove, "removing is the server's to refuse")
    }

    func testRemoveSendsTheirUserIDAndAnUnsupportedServerStopsTheOffer() async throws {
        try await signIn()
        let removing = Task { try await self.session.removeMember("bob", from: "general") }
        await expectSent(2, #"{"id":"c3","method":"room_leave","params":{"room_id":"general","user_id":"bob"}}"#)
        await socket.deliver(["id": "c3", "result": [:]])
        try await removing.value

        let adding = Task { try await self.session.addMember("carol", to: "general") }
        await expectSent(3, #"{"id":"c4","method":"room_join","params":{"room_id":"general","user_id":"carol"}}"#)
        await socket.deliver(["id": "c4", "error": ["code": -32601, "message": "unsupported"]])
        do {
            try await adding.value
            XCTFail("added")
        } catch {
            XCTAssertEqual((error as? RPCError)?.code, -32601)
        }
        XCTAssertFalse(session.mayChangeMembers(of: "general"))
        XCTAssertFalse(session.memberMenu(for: "bob", in: "general").remove)
        XCTAssertEqual(session.memberChangesRemark(in: "general"), "This server doesn’t let members add or remove others.")
    }
}
