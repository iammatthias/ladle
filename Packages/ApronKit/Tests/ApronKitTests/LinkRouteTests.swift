import XCTest
@testable import ApronKit

final class LinkRouteTests: XCTestCase {
    private let home = ServerRecord(id: UUID(uuidString: "6C61646C-0000-4000-8000-000000000001")!, url: URL(string: "wss://home.example/ws")!,
                                    account: ServerRecord.Account(userID: "sam", name: "Sam", scheme: "token"))
    /// A second account on home: a bot saved as its own record at the same URL.
    private let bot = ServerRecord(id: UUID(uuidString: "6C61646C-0000-4000-8000-000000000002")!, url: URL(string: "wss://home.example/ws")!,
                                   account: ServerRecord.Account(userID: "sous", name: "Sous Chef", scheme: "token"))

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

    func testAPlaceLinkOnAServerWithTwoAccountsGoesToTheOneThatSeesIt() throws {
        let place = try link("https://link.apron.chat/#server=wss://home.example/ws&room=ops&message=1793091900000")
        XCTAssertEqual(LinkRoute(place, records: [home, bot], sees: { $0 == bot.id }), .place(bot.id, place))
        XCTAssertEqual(LinkRoute(place, records: [home, bot], preferred: home.id, sees: { $0 == bot.id }), .place(bot.id, place),
                       "the account that can see the place comes before the open one")
    }

    func testAPlaceLinkBothAccountsSeeGoesToTheOpenOneElseAsks() throws {
        let place = try link("https://link.apron.chat/#server=wss://home.example/ws&room=general")
        XCTAssertEqual(LinkRoute(place, records: [home, bot], preferred: bot.id), .place(bot.id, place))
        XCTAssertEqual(LinkRoute(place, records: [home, bot], preferred: nil),
                       .chooseAccount(AccountChoice(link: place, token: nil, accounts: [home, bot])))
        let other = UUID(uuidString: "6C61646C-0000-4000-8000-000000000009")!
        XCTAssertEqual(LinkRoute(place, records: [home, bot], preferred: other),
                       .chooseAccount(AccountChoice(link: place, token: nil, accounts: [home, bot])), "another server open is no tiebreak")
        XCTAssertEqual(LinkRoute(place, records: [home, bot], preferred: nil, sees: { _ in false }),
                       .chooseAccount(AccountChoice(link: place, token: nil, accounts: [home, bot])), "no account sees it yet: all are offered")
    }

    func testASignInLinkOnAServerWithTwoAccountsAlwaysAsks() throws {
        let signIn = try link("https://link.apron.chat/#server=wss://home.example/ws&token=inv_Qm7x")
        let choice = AccountChoice(link: signIn, token: "inv_Qm7x", accounts: [home, bot])
        XCTAssertEqual(LinkRoute(signIn, records: [home, bot], preferred: home.id), .chooseAccount(choice))
        XCTAssertEqual(choice.title, "Sign in to home.example as…")
        XCTAssertEqual(choice.accounts.map(\.accountLabel), ["Sam", "Sous Chef"])
        XCTAssertEqual(choice.newAccount, TokenPayload(token: "inv_Qm7x", server: URL(string: "wss://home.example/ws")))
        XCTAssertEqual(AccountChoice.newAccountLabel, "Sign In as a New Account")
        XCTAssertEqual(choice.route(bot.id), .signIn(bot, TokenPayload(token: "inv_Qm7x", server: URL(string: "wss://home.example/ws"))))
        XCTAssertNil(choice.route(UUID()))
    }

    func testAPlaceChoiceWordsAndRoutes() throws {
        let place = try link("https://link.apron.chat/#server=wss://home.example/ws&room=general")
        var guest = bot
        guest.account = ServerRecord.Account(userID: "~g7", name: "Guest 7", scheme: "guest")
        var fresh = bot
        fresh.account = nil
        let choice = AccountChoice(link: place, token: nil, accounts: [home, guest, fresh])
        XCTAssertEqual(choice.title, "Open on home.example as…")
        XCTAssertEqual(choice.accounts.map(\.accountLabel), ["Sam", "Guest 7 (guest)", "Not signed in"])
        XCTAssertNil(choice.newAccount)
        XCTAssertEqual(choice.route(home.id), .place(home.id, place))
    }

    func testAnAccountWithoutANameIsItsUserID() {
        var record = home
        record.account = ServerRecord.Account(userID: "sam", scheme: "email")
        XCTAssertEqual(record.accountLabel, "@sam")
    }
}
