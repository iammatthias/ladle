import XCTest
@testable import ApronKit

final class ConnectFormTests: XCTestCase {
    private let link = "https://link.apron.chat/#server=wss://chat.example/ws&token=inv_Qm7x"
    private let saved = ServerRecord(url: URL(string: "wss://home.example/ws")!, label: "Home", origin: "https://web.apron.chat",
                                     account: ServerRecord.Account(userID: "sam", scheme: "email"))

    func testTheOriginFollowsTheAddressUntilTheUserChangesIt() {
        var form = ConnectForm(record: nil, mayWrite: false, prefill: nil)
        form.address = "wss://chat.example/ws"
        XCTAssertEqual(form.origin, "https://chat.example")
        form.address = "ws://localhost:8080/ws"
        XCTAssertEqual(form.origin, "https://localhost:8080")
        form.origin = "https://web.apron.chat"
        form.address = "wss://other.example/ws"
        XCTAssertEqual(form.origin, "https://web.apron.chat")
        form.address = "https://not.a.socket"
        XCTAssertNil(form.url)
        XCTAssertFalse(form.canSubmit(pendingEmail: nil))
    }

    func testASavedServerOpensWithItsFieldsAndLastMethod() {
        let form = ConnectForm(record: saved, mayWrite: true, prefill: nil)
        XCTAssertEqual([form.address, form.label, form.origin], ["wss://home.example/ws", "Home", "https://web.apron.chat"])
        XCTAssertEqual(form.method, .email)
        XCTAssertEqual(form.submitLabel(pendingEmail: nil), "Send Code")
        XCTAssertEqual(form.submitLabel(pendingEmail: "sam@example.com"), "Sign In")
        var guest = saved
        guest.account?.scheme = "guest"
        XCTAssertEqual(ConnectForm(record: guest, mayWrite: false, prefill: nil).method, .token, "not a guest the server lets only read")
        XCTAssertEqual(ConnectForm(record: guest, mayWrite: true, prefill: nil).method, .guest)
    }

    func testASignInLinkFillsTheServerAndTokenWhenAddingOne() {
        var form = ConnectForm(record: nil, mayWrite: false, prefill: nil)
        form.token = link
        XCTAssertEqual([form.address, form.token, form.origin], ["wss://chat.example/ws", "inv_Qm7x", "https://chat.example"])
        XCTAssertTrue(form.tokenReceived)
        XCTAssertEqual(form.submitLabel(pendingEmail: nil), "Connect")
        XCTAssertEqual(form.signIn(pendingEmail: nil), .token("inv_Qm7x"))
        form.token = "inv_Qm7"
        XCTAssertFalse(form.tokenReceived, "once the field no longer holds it")

        let opened = ConnectForm(record: nil, mayWrite: false, prefill: TokenPayload(token: "", server: URL(string: "wss://chat.example/ws")))
        XCTAssertEqual([opened.address, opened.token], ["wss://chat.example/ws", ""])
    }

    func testALinkForAnotherServerSaysSoAndFillsNothing() {
        var form = ConnectForm(record: saved, mayWrite: true, prefill: nil)
        form.accept(link)
        XCTAssertEqual(form.otherServer?.absoluteString, "wss://chat.example/ws")
        XCTAssertEqual([form.token, form.address], ["", "wss://home.example/ws"])
        XCTAssertEqual(form.method, .token)
        form.token = "st_abc"
        XCTAssertNil(form.otherServer, "typing a token clears it")
        form.accept("two words")
        XCTAssertEqual(form.token, "two words", "anything else lands as typed")
        XCTAssertFalse(form.canSubmit(pendingEmail: nil))
    }

    func testTheSignInFollowsTheMethod() {
        var form = ConnectForm(record: nil, mayWrite: false, prefill: nil)
        form.address = "wss://chat.example/ws"
        form.token = "apron_join_abc"
        form.accountName = "Mia"
        XCTAssertEqual(form.submitLabel(pendingEmail: nil), "Create Account")
        XCTAssertEqual(form.signIn(pendingEmail: nil), .signUp(invite: "apron_join_abc", name: "Mia"))
        form.method = .email
        form.email = " mia@example.com "
        XCTAssertTrue(form.canSubmit(pendingEmail: nil))
        XCTAssertEqual(form.signIn(pendingEmail: nil), .emailProposal(address: "mia@example.com"))
        XCTAssertFalse(form.canSubmit(pendingEmail: "mia@example.com"), "no code yet")
        form.code = " 123456 "
        XCTAssertEqual(form.signIn(pendingEmail: "mia@example.com"), .emailCode("123456"))
        form.code = link
        XCTAssertEqual(form.signIn(pendingEmail: "mia@example.com"), .token("inv_Qm7x"), "the link from the email")
        form.method = .guest
        XCTAssertEqual(form.signIn(pendingEmail: nil), .guest(name: nil))
    }

    func testTheMethodsAreThoseTheServerOffers() throws {
        XCTAssertEqual(ConnectForm.methods(offered: nil), [.token, .email, .guest])
        let server = try XCTUnwrap(ServerInfo(params: ["apron": 9, "auth": ["token", "guest"]]))
        XCTAssertEqual(ConnectForm.methods(offered: server), [.token, .guest])
        var form = ConnectForm(record: saved, mayWrite: true, prefill: nil)
        form.offer(ConnectForm.methods(offered: server))
        XCTAssertEqual(form.method, .token, "email is not offered")
    }

    func testTheSavedRecordDefaultsAnEmptyNameAndOrigin() {
        var form = ConnectForm(record: saved, mayWrite: true, prefill: nil)
        form.label = "  "
        form.origin = ""
        let record = form.saved(at: URL(string: "wss://home.example/v2")!)
        XCTAssertEqual([record.label, record.origin, record.url.absoluteString], ["home.example", "https://home.example", "wss://home.example/v2"])
        XCTAssertEqual(record.id, saved.id)
        XCTAssertEqual(record.account?.userID, "sam")
    }
}
