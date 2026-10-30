import XCTest
@testable import ApronKit

final class LinkRouteTests: XCTestCase {
    private let home = ServerRecord(id: UUID(uuidString: "6C61646C-0000-4000-8000-000000000001")!, url: URL(string: "wss://home.example/ws")!)

    private func link(_ text: String) throws -> ApronLink { try XCTUnwrap(ApronLink(URL(string: text)!)) }

    func testALinkToASavedServersPlaceOpensIt() throws {
        let place = try link("https://link.apron.chat/#server=wss://home.example/ws&room=general&message=1793091900000")
        XCTAssertEqual(LinkRoute(place, records: [home]), .place(home.id, place))
    }

    func testASignInLinkForASavedServerOpensItsSignInSheet() throws {
        let signIn = try link("https://link.apron.chat/#server=wss://home.example/ws&token=inv_Qm7x")
        XCTAssertEqual(LinkRoute(signIn, records: [home]),
                       .signIn(home, TokenPayload(token: "inv_Qm7x", server: URL(string: "wss://home.example/ws"))))
    }

    func testALinkToAnotherServerOffersToAddIt() throws {
        let other = try link("https://link.apron.chat/#server=wss://chat.example/ws&room=general")
        XCTAssertEqual(LinkRoute(other, records: [home]), .addServer(TokenPayload(token: "", server: URL(string: "wss://chat.example/ws")), place: other))
    }

    func testARelativeLinkGoesNowhere() throws {
        XCTAssertNil(LinkRoute(try link("apron:?room=general"), records: [home]))
    }

    func testATappedReminderOpensItsMessageWhileItsServerIsSaved() throws {
        let key = ReminderKey(server: home.id, roomID: "general", messageID: LogID("1793091900000")!)
        XCTAssertEqual(LinkRoute(key, records: [home]),
                       .place(home.id, ApronLink(server: home.url, room: "general", message: LogID("1793091900000"))))
        XCTAssertNil(LinkRoute(key, records: []))
    }
}
