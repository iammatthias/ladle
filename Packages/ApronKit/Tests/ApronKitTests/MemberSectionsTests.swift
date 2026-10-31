@testable import ApronKit
import Foundation
import XCTest

/// The member list as apron-web sections it: the status order, who goes under Online, one list
/// without presence, and a truncated listing's `member_count` (§4.2.1) in the count, the note,
/// the profile card and Message.
final class MemberSectionsTests: ScriptedSessionCase {
    /// Signs in as Ada with the rooms of `joined` (`members` and `member_count` as given), each
    /// member's object also in `users`, as servers send them.
    private func signIn(capabilities: [String] = ["history", "rooms", "status"], you: JSONValue = ["user_id": "ada", "name": "Ada", "status": "online"],
                        joined: [JSONValue]) async throws {
        let socket = queueTransport(capabilities: capabilities)
        session.start()
        await eventually("signed out") { session.status == .signedOut }
        let signIn = Task { try await session.signIn(.guest(name: nil)) }
        _ = await sent(socket, count: 2)
        await socket.deliver(["id": "c1", "result": ["you": you, "token": "t1"]])
        let users = joined.flatMap { $0["members"]?.arrayValue ?? [] }
        await socket.deliver(["id": "c2", "result": ["joined": .array(joined), "users": .array(users)]])
        _ = try await signIn.value
        await eventually("listed") { session.store.members(of: "general") != nil }
    }

    private func general(_ members: [JSONValue], count: Int? = nil) -> JSONValue {
        var room: [String: JSONValue] = ["room_id": "general", "log_id": "100", "title": "General", "latest_log_id": "100", "members": .array(members)]
        if let count { room["member_count"] = .number(String(count)) }
        return .object(room)
    }

    private func ids(_ sections: [MemberSection]) -> [String: [String]] {
        Dictionary(uniqueKeysWithValues: sections.map { ($0.key.rawValue, $0.people.map(\.userID)) })
    }

    func testMembersSortOnlineIdleDndUnknownOfflineThenNoneAndOnlyOfflineGoesUnderOffline() async throws {
        try await signIn(joined: [general([
            ["user_id": "zed", "name": "Zed", "status": "offline"],
            ["user_id": "yan", "name": "Yan"],
            ["user_id": "bea", "name": "Bea", "status": "brb"],
            ["user_id": "cal", "name": "Cal", "status": "dnd"],
            ["user_id": "dot", "name": "Dot", "status": "idle"],
            ["user_id": "eli", "name": "Eli", "status": "online"],
            ["user_id": "ada", "name": "Ada"],
            ["user_id": "abe", "name": "Abe", "status": "invisible"],
            ["user_id": "ann", "name": "Ann"],
        ])])
        let sections = session.memberSections("general")
        XCTAssertEqual(sections.map(\.title), ["Online", "Offline"])
        XCTAssertEqual(sections[0].people.map(\.userID), ["ada", "eli", "dot", "cal", "bea", "ann", "yan"],
                       "you (online), online, idle, dnd, unknown, then those with no status, by name within each")
        XCTAssertEqual(sections[1].people.map(\.userID), ["abe", "zed"], "invisible shows as offline")
    }

    func testWithoutStatusesOneMembersListByName() async throws {
        try await signIn(capabilities: ["history", "rooms"], joined: [general([
            ["user_id": "bea", "name": "Bea", "status": "offline"],
            ["user_id": "ann", "name": "Ann"],
        ])])
        XCTAssertEqual(ids(session.memberSections("general")), ["members": ["ann", "bea"]], "no capability status: no online or offline")
        XCTAssertEqual(session.memberSections("general").map(\.title), ["Members"])
        XCTAssertNil(session.memberListNote("general"))
        XCTAssertEqual(session.memberTotal("general"), 2)
    }

    func testWithStatusButNobodyHavingOneOneMembersList() async throws {
        try await signIn(you: ["user_id": "ada", "name": "Ada"], joined: [general([["user_id": "ann", "name": "Ann"], ["user_id": "ada", "name": "Ada"]])])
        XCTAssertEqual(ids(session.memberSections("general")), ["members": ["ada", "ann"]])
    }

    func testATruncatedListingSaysSoInTheCountTheNoteAndTheProfileCard() async throws {
        try await signIn(joined: [
            general([["user_id": "ann", "name": "Ann", "status": "online"], ["user_id": "ada", "name": "Ada"]], count: 240),
            ["room_id": "random", "log_id": "101", "title": "Random", "latest_log_id": "101",
             "members": [["user_id": "ada", "name": "Ada"]]],
        ])
        XCTAssertEqual(session.store.memberCount(of: "general"), 240)
        XCTAssertEqual(session.memberTotal("general"), 240)
        XCTAssertEqual(session.memberListNote("general"), "Showing 2 of 240: the most recently active")
        let bea = UserObject(["user_id": "bea", "name": "Bea"])!
        XCTAssertEqual(session.profile(of: bea, in: "general").membership, "Not among the recently active members of General")
        XCTAssertEqual(session.profile(of: bea, in: "random").membership, "Not in Random", "a complete listing")
        XCTAssertEqual(session.profile(of: UserObject(["user_id": "ann"])!, in: "general").membership, "Member of General")
        XCTAssertNil(session.store.memberCount(of: "random"))
        XCTAssertNil(session.memberListNote("random"))
    }

    func testACompleteListingClearsTheCount() {
        var store = ReplayStore()
        let truncated = Records(roomListResult: ["joined": [["room_id": "general", "latest_log_id": "100", "members": [["user_id": "ann"]], "member_count": 7]]])
        store.apply(truncated)
        XCTAssertEqual(store.memberCount(of: "general"), 7)
        store.apply(Records(roomListResult: ["joined": [["room_id": "general", "latest_log_id": "100"]]]))
        XCTAssertEqual(store.memberCount(of: "general"), 7, "a record without members says nothing of them")
        store.apply(Records(roomListResult: ["joined": [["room_id": "general", "latest_log_id": "101", "members": [["user_id": "ann"], ["user_id": "bea"]]]]]))
        XCTAssertNil(store.memberCount(of: "general"), "a list that is not truncated carries no count")
        store.apply(Records(roomListResult: ["joined": [["room_id": "general", "latest_log_id": "102", "members": [], "member_count": -1]]]))
        XCTAssertNil(store.memberCount(of: "general"), "a count that is not a non-negative integer is ignored")
    }

    func testMessageSkipsAConversationWhoseListingIsTruncated() async throws {
        try await signIn(joined: [
            general([["user_id": "ada", "name": "Ada"]]),
            ["room_id": "p1", "log_id": "102", "private": true, "latest_log_id": "102",
             "members": [["user_id": "ada", "name": "Ada"], ["user_id": "bea", "name": "Bea"]], "member_count": 2],
            ["room_id": "p2", "log_id": "103", "private": true, "latest_log_id": "103",
             "members": [["user_id": "ada", "name": "Ada"], ["user_id": "cal", "name": "Cal"]]],
        ])
        XCTAssertNil(session.directRoom(with: "bea"), "a truncated listing says nothing for sure")
        XCTAssertEqual(session.directRoom(with: "cal"), "p2")
    }
}
