import XCTest
@testable import ApronKit

@MainActor
final class MessageMenuTests: XCTestCase {
    func testAMessagesMenuFollowsWhatTheSessionAllows() async throws {
        let store = await PreviewFixtures.makeStore()
        let home = try XCTUnwrap(store.session(for: PreviewFixtures.homeID))
        let general = home.timeline("general")
        let own = try XCTUnwrap(general.first { $0.from.userID == "sam" })
        let ada = try XCTUnwrap(general.first { $0.from.userID == "ada" })
        let mine = MessageMenu(own, in: home), theirs = MessageMenu(ada, in: home)
        XCTAssertEqual([mine.reacts, mine.mayWrite, mine.editable, theirs.editable], [true, true, true, false])
        XCTAssertEqual(mine.moveDestinations, ["1793092125000"], "your own message moves to the room's threads")
        XCTAssertEqual(theirs.moveDestinations, [], "someone else's needs move_any")
        XCTAssertEqual(theirs.link?.absoluteString, "https://link.apron.chat/#server=wss://home.example/ws&room=general&message=\(ada.messageID.text)")
        XCTAssertEqual(theirs.text, ada.plainText)

        let linking = try XCTUnwrap(home.timeline(PreviewFixtures.linkCardRoomID).last)
        let menu = MessageMenu(linking, in: home)
        XCTAssertEqual(menu.links.map(\.title), ["apron:?room=1793092125000", "apron:?room=ops&message=1793074800000"], "a link without a host by its text")
        XCTAssertEqual(menu.selectableText, MessageText.plain(linking.body))

        let demo = try XCTUnwrap(store.session(for: PreviewFixtures.demoID))
        let guest = MessageMenu(demo.timeline("lobby")[0], in: demo)
        XCTAssertEqual([guest.mayWrite, guest.editable], [false, false], "a guest the demo lets only read")
    }

    func testANoticesMenuNamesWhoSentItAndOffersItsCode() async throws {
        let store = await PreviewFixtures.makeStore()
        let home = try XCTUnwrap(store.session(for: PreviewFixtures.homeID))
        let menu = NoticeMenu(try XCTUnwrap(home.notices.first), in: home)
        XCTAssertNil(menu.title, "a ~room notice")
        XCTAssertEqual(menu.code, [])
        XCTAssertEqual(menu.text, "Release freeze starts Friday at 18:00 UTC. Type /help for the commands here.")
        XCTAssertEqual(NoticeMenu(Notice(roomID: "general", from: UserObject(["user_id": "~private"])!, body: ["text": "hi"]), in: home).title,
                       "Only you can see this")
        let token = Notice(roomID: "general", from: UserObject(["user_id": "~server"])!,
                           body: ["text": "Your token: `apron_invite_x`. Run `/invite-device phone` or see https://home.example/docs", "format": "markdown"])
        let server = NoticeMenu(token, in: home)
        XCTAssertEqual(server.title, "Home")
        XCTAssertEqual(server.code, ["apron_invite_x", "/invite-device phone"])
        XCTAssertEqual(server.links.map(\.shared.absoluteString), ["https://home.example/docs"])
        XCTAssertEqual(server.text, "Your token: apron_invite_x. Run /invite-device phone or see https://home.example/docs")
        XCTAssertNil(NoticeMenu(Notice(roomID: "general", from: UserObject(["user_id": "~room"])!, body: ["text": "hi"]), in: home).title)
        XCTAssertEqual(NoticeMenu(Notice(roomID: "general", from: UserObject(["user_id": "ada"])!, body: ["text": "hi"]), in: home).title, "Ada Okafor")
    }
}
