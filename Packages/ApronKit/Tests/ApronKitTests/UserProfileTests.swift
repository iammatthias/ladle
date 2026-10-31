import Foundation
import XCTest
@testable import ApronKit

/// The profile card (`UserProfile`), its last-seen words, Mention, and Add to room.
@MainActor
final class UserProfileTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    private func home() async throws -> ServerSession {
        let store = await PreviewFixtures.makeStore()
        return try XCTUnwrap(store.session(for: PreviewFixtures.homeID))
    }

    func testACardShowsWhoTheyAreTheirBioAndWhetherTheyAreInTheRoom() async throws {
        let home = try await home()
        let ada = home.profile(of: UserObject(["user_id": "ada"])!, in: "general")
        XCTAssertEqual(ada.name, "Ada Okafor")
        XCTAssertEqual(ada.status, "Online")
        XCTAssertEqual(ada.roles, ["admin"])
        XCTAssertEqual(ada.bio, "Runs this server. Ask me about the paging floor, or soup.")
        XCTAssertEqual(ada.membership, "Member of general")
        XCTAssertFalse(ada.isYou)
        XCTAssertTrue(ada.mayMention)
        XCTAssertFalse(ada.mayAddToRoom, "already a member")

        let inOps = home.profile(of: UserObject(["user_id": "ada"])!, in: "ops")
        XCTAssertEqual(inOps.membership, "Not in ops")
        XCTAssertTrue(inOps.mayAddToRoom, "a private room you are in takes people without add_members")
        XCTAssertTrue(home.profile(of: UserObject(["user_id": "chiara"])!, in: "kitchen").mayAddToRoom,
                      "without ext:permissions, any room takes people, as PROTOCOL.md allows")
        XCTAssertNil(home.profile(of: UserObject(["user_id": "ada"])!, in: nil).membership)

        let you = home.profile(of: UserObject(["user_id": "sam"])!, in: "general")
        XCTAssertTrue(you.isYou)
        XCTAssertEqual(you.status, "Online")
        XCTAssertFalse(you.mayAddToRoom)
    }

    func testAnOfflinePersonSaysWhenTheyWereLastSeen() async throws {
        let home = try await home()
        let seen = try XCTUnwrap(home.users.user("dev")?["seen"]?.stringValue)
        let now = Date(timeIntervalSince1970: (Double(seen)! / 1000) + 3 * 3600 + 120)
        let dev = home.profile(of: UserObject(["user_id": "dev"])!, in: "general", now: now, calendar: utc)
        XCTAssertEqual(dev.status, "Offline")
        XCTAssertEqual(dev.presence, .offline)
        XCTAssertEqual(dev.lastSeen, "Last seen 3h ago")
        XCTAssertEqual(dev.roles, ["bot"])
        XCTAssertNil(home.profile(of: UserObject(["user_id": "ada"])!, in: "general", now: now).lastSeen, "only while offline")
    }

    func testLastSeenWordsFollowTheWeb() {
        let seen = "1793091600000" // 2026-10-27 09:00 UTC
        let at = Date(timeIntervalSince1970: 1_793_091_600)
        func words(after seconds: TimeInterval) -> String? { LastSeen.text(seen, now: at.addingTimeInterval(seconds), calendar: utc) }
        XCTAssertEqual(words(after: 9 * 60), "Last seen recently")
        XCTAssertEqual(words(after: -4 * 60), "Last seen recently", "a clock a little behind")
        XCTAssertEqual(words(after: 15 * 60), "Last seen 15m ago")
        XCTAssertEqual(words(after: 25 * 3600), "Last seen 1d ago")
        XCTAssertEqual(words(after: 13 * 86400), "Last seen 13d ago")
        XCTAssertEqual(words(after: 20 * 86400), "Last seen Oct 27")
        XCTAssertEqual(words(after: 90 * 86400), "Last seen Oct 27, 2026")
        XCTAssertEqual(words(after: -3600), "Last seen Oct 27", "far ahead names the day")
        XCTAssertNil(LastSeen.text("0123", now: at))
        XCTAssertNil(LastSeen.text(nil, now: at))
    }

    func testANameAnotherUserSharesIsFlagged() {
        var users = UserDirectory()
        users.merge(UserObject(["user_id": "ada", "name": "Ada"])!)
        users.merge(UserObject(["user_id": "ada2", "name": "Ada"])!)
        users.merge(UserObject(["user_id": "bram", "name": "Bram\u{202E}"])!)
        XCTAssertTrue(users.sharesName(UserObject(["user_id": "ada"])!))
        XCTAssertEqual(users.plainName(for: UserObject(["user_id": "ada"])!), "Ada")
        XCTAssertEqual(users.displayName(for: UserObject(["user_id": "ada"])!), "\u{2068}Ada\u{2069} (@ada)")
        XCTAssertFalse(users.sharesName(UserObject(["user_id": "bram"])!))
        XCTAssertEqual(users.plainName(for: UserObject(["user_id": "bram"])!), "Bram")
        XCTAssertEqual(users.plainName(for: UserObject(["user_id": "wren", "name": "Wren"])!), "Wren", "the recorded name")
    }

    func testMentionAppendsToTheDraft() {
        var field = DraftField(text: "Thanks")
        field.mention("ada", named: "Ada Okafor")
        XCTAssertEqual(field.text, "Thanks @Ada Okafor ")
        XCTAssertEqual(field.mentions, ["ada": "Ada Okafor"])
        var empty = DraftField()
        empty.mention("bram", named: "Bram")
        XCTAssertEqual(empty.text, "@Bram ")
    }

    func testAMentionChipLinksToItsUserAndLeavesTheTextsLinksAlone() {
        let body: JSONValue = ["text": "@Ada see https://git.example/x", "format": "plain"]
        let text = MessageText.attributed(body, mentions: ["ada": "Ada"])
        let chip = text.runs.first { $0[MentionKey.self] != nil }
        XCTAssertEqual(chip?.link?.absoluteString, "apron:?user=ada")
        XCTAssertEqual(ApronLink(chip!.link!)?.user, "ada")
        XCTAssertEqual(MessageText.links(body).map(\.absoluteString), ["https://git.example/x"])
    }
}
