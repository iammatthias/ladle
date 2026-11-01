import Foundation
import Synchronization
import XCTest
@testable import ApronKit

/// Private rooms and direct messages (§4.2.4), as apron-web's `private-rooms.ts`: names, the
/// Private list, the conversation you already have, starting one, adding its people, the limit,
/// the intro card, and the rooms someone else added you to.
@MainActor
final class PrivateRoomsTests: XCTestCase {
    private func home() async throws -> ServerSession {
        let store = await PreviewFixtures.makeStore()
        return try XCTUnwrap(store.session(for: PreviewFixtures.homeID))
    }

    func testAnUntitledPrivateRoomIsNamedForItsOtherMembers() {
        XCTAssertEqual(PeopleTitle.title([]), "You")
        XCTAssertEqual(PeopleTitle.title(["mira", "Émile", "Dev"]), "Dev, Émile, mira")
        XCTAssertEqual(PeopleTitle.title(["Bob\u{202E}evil"]), "Bobevil", "bidi overrides dropped")
        XCTAssertEqual(PeopleTitle.line(others: [], status: nil), "Only you can see this room")
        XCTAssertEqual(PeopleTitle.line(others: ["Bob"], status: "Online"), "Online · only you and Bob can see this room")
        XCTAssertEqual(PeopleTitle.line(others: ["Bob"], status: nil), "Only you and Bob can see this room")
        XCTAssertEqual(PeopleTitle.line(others: ["Bob", "Carol"], status: nil), "Only members can see this room")
    }

    func testTheRoomsListKeepsPrivateRoomsInTheirOwnSection() async throws {
        let home = try await home()
        XCTAssertEqual(home.privateRoomTree.map { home.title(of: $0.roomID) }, ["Ada Okafor", "Bram, Chiara", "Launch plan", "ops"])
        XCTAssertEqual(home.publicRoomTree.map { home.title(of: $0.roomID) }, ["design", "general", "kitchen", "markdown", "random", "remote"])
        XCTAssertEqual(home.faces(of: PreviewFixtures.groupRoomID).map(\.userID), ["bram", "chiara"])
        XCTAssertEqual(home.headerLine(PreviewFixtures.directRoomID, typing: nil, copied: false, descriptionPutAway: false),
                       .privateRoom("Online · only you and Ada Okafor can see this room"))
        XCTAssertEqual(home.headerLine(PreviewFixtures.groupRoomID, typing: nil, copied: false, descriptionPutAway: false),
                       .privateRoom("Only members can see this room"))
        XCTAssertNil(home.headerLine("ops", typing: nil, copied: false, descriptionPutAway: false), "a titled private room has no line")
    }

    func testTheConversationYouHaveWithSomeoneIsFoundAndMessageOpensIt() async throws {
        let home = try await home()
        XCTAssertEqual(home.directRoom(with: "ada"), PreviewFixtures.directRoomID)
        XCTAssertNil(home.directRoom(with: "bram"), "only a room of just the two of you")
        XCTAssertNil(home.directRoom(with: "dev"), "a titled room is not a conversation")
        let started = try await home.message("ada")
        XCTAssertEqual(started, StartedRoom(roomID: PreviewFixtures.directRoomID, refused: []))
        XCTAssertEqual(home.privatePeople(PeoplePicker()).map { "\($0.name)\($0.existing ? " · open" : "")" },
                       ["Ada Okafor · open", "Bram", "Chiara", "Dev", "Eun-ji"])
        var picker = PeoplePicker()
        picker.query = "@EU"
        XCTAssertEqual(home.privatePeople(picker).map(\.userID), ["eunji"])
        XCTAssertTrue(home.profile(of: UserObject(["user_id": "ada"])!, in: "general").mayMessage)
        XCTAssertFalse(home.profile(of: UserObject(["user_id": "sam"])!, in: "general").mayMessage, "not to yourself")
    }

    func testStartingAPrivateRoomCountsAgainstTheServersLimit() async throws {
        let home = try await home()
        XCTAssertEqual(home.privateRoomQuota?.used, 4)
        XCTAssertEqual(home.privateRoomQuota?.max, 5)
        XCTAssertFalse(home.atPrivateRoomLimit)
        XCTAssertEqual(home.privateRoomsQuietestFirst, ["ops", PreviewFixtures.directRoomID, PreviewFixtures.groupRoomID, PreviewFixtures.addedRoomID])

        let started = try await home.startPrivateRoom(with: [])
        XCTAssertEqual(started.roomID, "new_1")
        XCTAssertEqual(home.title(of: "new_1"), "You", "alone in it")
        XCTAssertEqual(home.privateRoomQuota?.used, 5)
        XCTAssertTrue(home.atPrivateRoomLimit)
        XCTAssertFalse(home.wasAdded(to: "new_1"), "a room you started is not one you were added to")
    }

    func testTheIntroCardHeadsAPrivateRoomWhoseHistoryReachesItsStart() async throws {
        let home = try await home()
        let intro = try XCTUnwrap(home.privateIntro(PreviewFixtures.directRoomID))
        XCTAssertEqual(intro.name, "Ada Okafor")
        XCTAssertEqual(intro.faces.map(\.userID), ["ada"])
        XCTAssertEqual(intro.detail, "@ada · Runs this server. Ask me about the paging floor, or soup.")
        XCTAssertNil(home.privateIntro(PreviewFixtures.groupRoomID), "its history starts after the room did")
        XCTAssertNil(home.privateIntro("general"), "not private")
    }

    func testTheLimitIsACountUnderExtSettings() {
        func limit(_ value: JSONValue, capability: Bool = true) -> Int? {
            ServerInfo(params: ["apron": 9, "auth": ["token"], "capabilities": capability ? ["ext:settings"] : [], "ext": ["settings": ["private_rooms": value]]])?.privateRoomLimit
        }
        XCTAssertEqual(limit(5), 5)
        XCTAssertEqual(limit(0), 0)
        XCTAssertNil(limit(2.5))
        XCTAssertNil(limit(-1))
        XCTAssertNil(limit("5"))
        XCTAssertNil(limit(5, capability: false))
    }

    func testAUserIDTypedWholeIsTheOnlyWayToNameSomeoneUnknown() {
        XCTAssertEqual(PeoplePicker.userID(typed: " @carol "), "carol")
        XCTAssertEqual(PeoplePicker.userID(typed: "carol"), "carol")
        XCTAssertNil(PeoplePicker.userID(typed: "Carol Smith"))
        XCTAssertNil(PeoplePicker.userID(typed: "@"))
        var picker = PeoplePicker()
        picker.toggle("ada")
        picker.toggle("bram")
        picker.toggle("ada")
        XCTAssertEqual(picker.chosen, ["bram"])
        XCTAssertEqual(ServerSession.startWords(chosen: ["ada"], saving: false), "Message")
        XCTAssertEqual(ServerSession.startWords(chosen: ["ada", "bram"], saving: false), "Start")
        XCTAssertEqual(ServerSession.startWords(chosen: ["ada"], saving: true), "Starting…")
        XCTAssertEqual(Refusal.words([Refusal(userID: "carol", message: "Unknown user. "), Refusal(userID: "dan", message: "denied")], name: { $0.capitalized }),
                       "Couldn’t add Carol: Unknown user. Couldn’t add Dan: denied.")
    }

    // MARK: Against a scripted server

    private let record = ServerRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000000009")!, url: URL(string: "wss://chat.example/ws")!)
    private var session: ServerSession!
    private var socket: FakeTransport!

    override func tearDown() async throws {
        await session?.stop()
    }

    /// Signed in with a token as Ada, in `general` with Bob and Carol, and in the private room `p0`
    /// with Bob. `early` arrives between the `auth` result and the listing.
    private func signIn(early: JSONValue? = nil) async throws {
        let tokens = InMemoryTokenStore()
        try tokens.setToken("t1", for: record.id)
        let counter = Mutex(0)
        let socket = FakeTransport()
        self.socket = socket
        let environment = ServerSession.Environment(
            makeTransport: { _ in socket },
            sleep: { _ in try await Task.sleep(for: .seconds(3600)) },
            jitter: { 1 },
            makeRequestID: { counter.withLock { $0 += 1; return "c\($0)" } }
        )
        session = ServerSession(record: record, tokens: tokens, environment: environment)
        Task { await socket.deliver(["method": "server", "params": ["apron": 9, "auth": ["token"], "capabilities": ["history", "rooms"]]]) }
        session.start()
        await eventually("auth and room_list") { await socket.sentLog.count >= 2 }
        await socket.deliver(["id": "c1", "result": ["you": ["user_id": "ada", "name": "Ada"]]])
        if let early { await socket.deliver(early) }
        await socket.deliver(["id": "c2", "result": ["joined": [
            ["room_id": "general", "log_id": "100", "title": "General", "members": [["user_id": "ada"], ["user_id": "bob"], ["user_id": "carol"]]],
            ["room_id": "p0", "log_id": "101", "private": true, "members": [["user_id": "ada"], ["user_id": "bob"]]],
        ], "users": [["user_id": "bob", "name": "Bob"], ["user_id": "carol", "name": "Carol"]]]])
        await eventually("signed in") { self.session.status == .signedIn && self.session.joinedRoomIDs.count == 2 }
    }

    private func sent(_ index: Int) async -> String {
        await eventually("frame \(index)") { await self.socket.sentLog.count > index }
        return await socket.sentLog[index]
    }

    private func expectSent(_ index: Int, _ expected: String, file: StaticString = #filePath, line: UInt = #line) async {
        let frame = await sent(index)
        XCTAssertEqual(frame, expected, file: file, line: line)
    }

    func testAPrivateRoomStartsThenAddsEachPersonAndSaysWhoWasRefused() async throws {
        try await signIn()
        let starting = Task { try await self.session.startPrivateRoom(with: ["bob", "carol"], title: "  ") }
        await expectSent(2, #"{"id":"c3","method":"room_set","params":{"private":true}}"#)
        await socket.deliver(["method": "room_update", "params": ["joined": [["room_id": "p1", "log_id": "200", "private": true, "members": [["user_id": "ada"]]]]]])
        await socket.deliver(["id": "c3", "result": ["room_id": "p1"]])
        await expectSent(3, #"{"id":"c4","method":"room_join","params":{"room_id":"p1","user_id":"bob"}}"#)
        await socket.deliver(["id": "c4", "result": [:]])
        await expectSent(4, #"{"id":"c5","method":"room_join","params":{"room_id":"p1","user_id":"carol"}}"#)
        await socket.deliver(["id": "c5", "error": ["code": -32001, "message": "Carol takes no new private rooms"]])
        let started = try await starting.value
        XCTAssertEqual(started, StartedRoom(roomID: "p1", refused: [Refusal(userID: "carol", message: "Carol takes no new private rooms")]))
        XCTAssertFalse(session.wasAdded(to: "p1"), "a room this device started")
    }

    func testARoomThatComesBackPublicAddsNoOne() async throws {
        try await signIn()
        let starting = Task { try await self.session.startPrivateRoom(with: ["bob"], title: "Plans") }
        await expectSent(2, #"{"id":"c3","method":"room_set","params":{"private":true,"title":"Plans"}}"#)
        await socket.deliver(["method": "room_update", "params": ["joined": [["room_id": "p2", "log_id": "200", "title": "Plans"]]]])
        await socket.deliver(["id": "c3", "result": ["room_id": "p2"]])
        do {
            _ = try await starting.value
            XCTFail("a public room was kept as private")
        } catch {
            XCTAssertEqual(error as? PrivateRoomError, .notPrivate(title: "Plans"))
            XCTAssertEqual(error.localizedDescription,
                           "The server made “Plans” an ordinary room that others can see and join, not a private one. Leave it, or use it knowing that.")
        }
        let frames = await socket.sentLog.count
        XCTAssertEqual(frames, 3, "no room_join sent")
    }

    func testAServerWithoutPrivateRoomsSaysSo() async throws {
        try await signIn()
        let starting = Task { try await self.session.createRoom(title: "Plans", isPrivate: true) }
        await expectSent(2, #"{"id":"c3","method":"room_set","params":{"private":true,"title":"Plans"}}"#)
        await socket.deliver(["id": "c3", "error": ["code": -32601, "message": "unsupported"]])
        do {
            _ = try await starting.value
            XCTFail("created")
        } catch {
            XCTAssertEqual(error.localizedDescription, "This server doesn’t keep private rooms. Uncheck Private to create an ordinary room.")
        }
    }

    func testARoomSomeoneElseAddedYouToGetsItsBannerUntilDismissed() async throws {
        try await signIn()
        XCTAssertFalse(session.wasAdded(to: "p0"), "rooms listed at sign-in are known")
        await socket.deliver(["method": "room_update", "params": ["joined": [["room_id": "p3", "log_id": "300", "private": true,
                                                                               "members": [["user_id": "ada"], ["user_id": "carol"]]]]]])
        await socket.deliver(["method": "room_update", "params": ["joined": [["room_id": "pub", "log_id": "301", "title": "Public"]]]])
        await eventually("both arrived") { self.session.joinedRoomIDs.contains("pub") }
        XCTAssertTrue(session.wasAdded(to: "p3"))
        XCTAssertFalse(session.wasAdded(to: "pub"), "only private rooms get the banner")
        XCTAssertEqual(session.title(of: "p3"), "Carol")
        session.dismissAdded("p3")
        XCTAssertFalse(session.wasAdded(to: "p3"))
    }

    func testARoomSomeoneAddedYouToCountsUnreadFromYourJoin() async throws {
        try await signIn()
        await socket.deliver(["method": "room_update", "params": ["joined": [["room_id": "pub", "log_id": "301", "title": "Public"]]]])
        await eventually("arrived") { self.session.joinedRoomIDs.contains("pub") }
        func said(_ id: String, in room: String = "pub") -> JSONValue {
            ["method": "message", "params": ["message_id": .string(id), "log_id": .string(id), "room_id": .string(room),
                                             "from": ["user_id": "bob"], "body": ["text": "hi"]]]
        }
        for id in ["302", "310", "311"] { await socket.deliver(said(id)) }
        await eventually("messages") { self.session.timeline("pub").count == 3 }
        XCTAssertEqual(session.unreadCount(in: "pub"), 3, "every message until your join is loaded")
        await socket.deliver(["method": "room_update", "params": ["memberships": [
            ["log_id": "305", "room_id": "pub", "members": [["user": ["user_id": "ada", "name": "Ada"], "joined": true]]],
        ]]])
        await eventually("membership") { self.session.joinFloor(of: "pub") != nil }
        XCTAssertEqual(session.joinFloor(of: "pub"), LogID("305"))
        XCTAssertEqual(session.unreadCount(in: "pub"), 2, "what came before your join is not unread")

        for id in ["320", "321"] { await socket.deliver(said(id, in: "general")) }
        await eventually("general") { self.session.timeline("general").count == 2 }
        XCTAssertNil(session.joinFloor(of: "general"), "a room listed at sign-in")
        XCTAssertEqual(session.unreadCount(in: "general"), 2)
    }

    func testARoomArrivingBeforeTheListingIsNotTakenAsAdded() async throws {
        try await signIn(early: ["method": "room_update", "params": ["joined": [["room_id": "general", "log_id": "100", "title": "General"]]]])
        XCTAssertFalse(session.wasAdded(to: "p0"))
        XCTAssertFalse(session.wasAdded(to: "general"))
    }

    func testAThreadOfAPrivateRoomAddsTheRoomsOtherMembers() async throws {
        try await signIn()
        let creating = Task { try await self.session.createRoom(title: "Plans", parentRoomID: "p0") }
        await expectSent(2, #"{"id":"c3","method":"room_set","params":{"parent_room_id":"p0","title":"Plans"}}"#)
        await socket.deliver(["method": "room_update", "params": ["joined": [["room_id": "t1", "log_id": "400", "parent_room_id": "p0", "private": true, "title": "Plans"]]]])
        await socket.deliver(["id": "c3", "result": ["room_id": "t1"]])
        let thread = try await creating.value
        XCTAssertEqual(thread, "t1")
        let including = Task { await self.session.includeMembers(of: "p0", in: "t1") }
        await expectSent(3, #"{"id":"c4","method":"room_join","params":{"room_id":"t1","user_id":"bob"}}"#)
        await socket.deliver(["id": "c4", "error": ["code": -32001, "message": "Bob is away."]])
        let note = await including.value
        XCTAssertEqual(note, "Couldn’t add Bob: Bob is away.")
    }

    func testAThreadOfAPrivateRoomThatComesBackPublicIsRefused() async throws {
        try await signIn()
        let creating = Task { try await self.session.createRoom(title: "Plans", parentRoomID: "p0") }
        _ = await sent(2)
        await socket.deliver(["method": "room_update", "params": ["joined": [["room_id": "t2", "log_id": "400", "parent_room_id": "p0", "title": "Plans"]]]])
        await socket.deliver(["id": "c3", "result": ["room_id": "t2"]])
        do {
            _ = try await creating.value
            XCTFail("a public thread of a private room was opened")
        } catch {
            XCTAssertEqual(error as? PrivateRoomError, .threadNotPrivate)
        }
    }
}
