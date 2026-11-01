import XCTest
@testable import ApronKit

final class PasskeysTests: XCTestCase {
    private func challenge(_ publicKey: JSONValue, _ action: PasskeyAction, server: String) throws -> PasskeyChallenge {
        try PasskeyChallenge(result: ["challenge_id": "ch1", "public_key": publicKey], action: action, server: URL(string: server)!)
    }

    private func refusal(_ publicKey: JSONValue, _ action: PasskeyAction, server: String) -> String? {
        do {
            _ = try challenge(publicKey, action, server: server)
            return nil
        } catch let error as PasskeyError {
            return error.message
        } catch {
            return "\(error)"
        }
    }

    /// The RP ID vectors of apron-web's `webauthn.test.ts` (#183), with a native app's missing
    /// RP ID read as the server's host.
    func testTheRelyingPartyMustBeTheServersHostOrADomainItIsUnder() throws {
        let user: JSONValue = ["id": "dXNlcg", "name": "ada", "displayName": "Ada"]
        XCTAssertNil(refusal(["challenge": "AAEC", "rp": ["id": "apron.chat"], "user": user], .register, server: "wss://server.apron.chat/"))
        XCTAssertNil(refusal(["challenge": "AAEC", "rpId": "apron.chat"], .login, server: "wss://server.apron.chat/"))
        XCTAssertEqual(try challenge(["challenge": "AAEC", "rpId": "Server.Apron.Chat"], .login, server: "wss://server.apron.chat/").rpID, "server.apron.chat")
        XCTAssertEqual(try challenge(["challenge": "AAEC", "rpId": "localhost"], .login, server: "ws://localhost:8787/").rpID, "localhost")
        XCTAssertEqual(refusal(["challenge": "AAEC", "rpId": "apron.chat"], .login, server: "wss://evil.example/"),
                       "This server (evil.example) asked for a passkey for apron.chat, which is not its own.")
        XCTAssertEqual(refusal(["challenge": "AAEC", "rpId": "apron.chat"], .login, server: "wss://notapron.chat/"),
                       "This server (notapron.chat) asked for a passkey for apron.chat, which is not its own.")
        XCTAssertEqual(try challenge(["challenge": "AAEC", "rp": ["id": "apron.chat"]], .login, server: "wss://server.apron.chat/").rpID,
                       "server.apron.chat", "a login's RP ID is rpId alone; without it, the server's host")
        XCTAssertEqual(refusal(["challenge": "AAEC", "rpId": "apron.chat"], .login, server: "not a url"),
                       "Passkeys need a server address with a host name.")
        XCTAssertEqual(refusal(["rpId": "apron.chat"], .login, server: "wss://server.apron.chat/"), "Invalid passkey options from server")
    }

    func testRegistrationOptionsGiveTheUserHandleTheExclusionsAndTheChallenge() throws {
        let options = try challenge([
            "challenge": "AAECAw", "rp": ["id": "chat.example", "name": "Chat"],
            "user": ["id": "aGFuZGxl", "name": "guest_7", "displayName": "Guest 7"],
            "excludeCredentials": [["type": "public-key", "id": "Y3JlZA"]],
            "authenticatorSelection": ["residentKey": "required", "userVerification": "required"],
        ], .register, server: "wss://chat.example/ws")
        XCTAssertEqual(options.challengeID, "ch1")
        XCTAssertEqual(options.challenge, Data([0, 1, 2, 3]))
        XCTAssertEqual(options.user, PasskeyChallenge.User(id: Data("handle".utf8), name: "guest_7", displayName: "Guest 7"))
        XCTAssertEqual(options.excludedCredentials, [Data("cred".utf8)])
        XCTAssertEqual(options.userVerification, "required")
        XCTAssertEqual(options.passkeyName(labelled: "  Ada "), "Ada")
        XCTAssertEqual(options.passkeyName(labelled: nil), "guest_7")
    }

    func testTheAppMustBeAssociatedAndTheOriginMustBeTheOneThePlatformSigns() throws {
        let options = try challenge(["challenge": "AAEC", "rpId": "chat.example"], .login, server: "wss://chat.example/ws")
        XCTAssertNoThrow(try options.check(domains: PasskeyDomains("chat.example"), origin: "https://chat.example"))
        XCTAssertNoThrow(try options.check(domains: PasskeyDomains("other.example, Chat.Example"), origin: "https://CHAT.example/"))
        XCTAssertThrowsError(try options.check(domains: .none, origin: "https://chat.example")) { error in
            XCTAssertEqual((error as? PasskeyError)?.message,
                           "Ladle can’t use passkeys for chat.example: only apps that domain lists can. Sign in with your passkey in a web browser, get a token for this device there (such as with /invite-device add), and paste it here.")
        }
        XCTAssertThrowsError(try options.check(domains: PasskeyDomains("chat.example"), origin: "https://web.apron.chat")) { error in
            XCTAssertEqual((error as? PasskeyError)?.message,
                           "Passkeys for chat.example sign in from https://chat.example, but this server is set to the origin https://web.apron.chat. Change the origin under Name and Origin, then try again.")
        }
    }

    func testAWildcardDomainCoversSubdomainsButNotItself() {
        let domains = PasskeyDomains("*.example.org home.example")
        XCTAssertTrue(domains.covers("chat.example.org"))
        XCTAssertFalse(domains.covers("example.org"))
        XCTAssertTrue(domains.covers("home.example"))
        XCTAssertFalse(domains.covers("sub.home.example"))
        XCTAssertTrue(domains.covers(server: URL(string: "wss://home.example/ws")!))
        XCTAssertTrue(PasskeyDomains("example.org").covers(server: URL(string: "wss://chat.example.org/ws")!), "a parent domain may be the RP ID")
        XCTAssertFalse(PasskeyDomains("example.org").covers(server: URL(string: "wss://server.apron.chat/")!))
    }

    func testAReturnedPageGivesItsTokenAndState() {
        XCTAssertEqual(SignInFragment(URL(string: "https://home.example/#token=Hk41x9&state=q8Rz&server=wss%3A%2F%2Fhome.example%2Fws")!),
                       SignInFragment(token: "Hk41x9", state: "q8Rz"))
        XCTAssertNil(SignInFragment(URL(string: "https://home.example/#state=q8Rz")!))
        XCTAssertNil(SignInFragment(URL(string: "https://home.example/")!))
    }

    func testARegistrationGoesAsWebAuthnJSON() {
        let credential = PasskeyCredential.registration(id: Data([0xFB, 0xFF]), clientDataJSON: Data("{}".utf8),
                                                        attestationObject: Data([0xA0]), attachment: .platform)
        XCTAssertEqual(credential.json.serialized(),
                       #"{"authenticatorAttachment":"platform","clientExtensionResults":{},"id":"-_8","rawId":"-_8","response":{"attestationObject":"oA","clientDataJSON":"e30"},"type":"public-key"}"#)
    }

    func testAnAssertionGoesAsWebAuthnJSON() {
        let credential = PasskeyCredential.assertion(id: Data([1]), clientDataJSON: Data("{}".utf8), authenticatorData: Data([2, 3]),
                                                     signature: Data([4]), userHandle: Data("u".utf8), attachment: nil)
        XCTAssertEqual(credential.json.serialized(),
                       #"{"clientExtensionResults":{},"id":"AQ","rawId":"AQ","response":{"authenticatorData":"AgM","clientDataJSON":"e30","signature":"BA","userHandle":"dQ"},"type":"public-key"}"#)
    }

    func testBase64URLReadsUnpaddedPaddedAndPlain() {
        XCTAssertEqual(Base64URL.encode(Data([0xFB, 0xFF, 0xBF])), "-_-_")
        XCTAssertEqual(Base64URL.decode("-_-_"), Data([0xFB, 0xFF, 0xBF]))
        XCTAssertEqual(Base64URL.decode("AQI"), Data([1, 2]))
        XCTAssertEqual(Base64URL.decode("AQI="), Data([1, 2]))
        XCTAssertNil(Base64URL.decode("*"))
    }
}

final class SignInLinksTests: XCTestCase {
    private let home = ServerRecord(id: UUID(uuidString: "6C61646C-0000-4000-8000-000000000001")!, url: URL(string: "wss://home.example/ws")!)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testTheLinkDialogWarnsAndOffersToAddWhereSignedIn() {
        let add = SignInLinkPrompt(host: "home.example", addAs: "Ada", keptSession: false)
        XCTAssertEqual(add.title, "Use this link on home.example?")
        XCTAssertEqual(add.lines, [
            "If you asked to add this way of signing in to Ada, on this device or another, add it.",
            "If you asked to sign in with it, signing in signs you out of Ada and in to the account the link is for.",
            "Only sign in if you just asked to, on this device or another. A link someone sent you can sign you in to their account.",
        ])
        XCTAssertTrue(add.adds)
        let kept = SignInLinkPrompt(host: "home.example", addAs: nil, keptSession: true)
        XCTAssertEqual(kept.title, "Sign in to home.example with this link?")
        XCTAssertEqual(kept.lines, [
            "You have a saved session here. Continuing signs you out of it.",
            "Only continue if you just asked to sign in, on this device or another. A link someone sent you can sign you in to their account.",
        ])
        XCTAssertFalse(kept.adds)
        XCTAssertEqual(SignInLinkPrompt(host: "home.example", addAs: nil, keptSession: false).lines.count, 1)
    }

    func testTheNudgeSuggestsWhatTheServerSignsInWithUntilTheAccountHasOne() {
        XCTAssertEqual(WayBack.suggested(auth: ["webauthn", "email", "token"], methods: ["token"]), [.webauthn, .email])
        XCTAssertNil(WayBack.suggested(auth: ["webauthn", "email", "token"], methods: ["token", "email"]))
        XCTAssertNil(WayBack.suggested(auth: ["email", "token"], methods: ["link"]), "a link is an email or external sign-in")
        XCTAssertEqual(WayBack.suggested(auth: ["webauthn", "token"], methods: ["link"]), [.webauthn])
        XCTAssertNil(WayBack.suggested(auth: ["token", "guest"], methods: ["token"]), "nothing to add")
        XCTAssertEqual(WayBack.words([.webauthn, .email, .external]), "a passkey, an email or an external sign-in")
        XCTAssertEqual(WayBack.hint([.webauthn], signedInWithToken: true),
                       "Only this device’s saved session gets you back into this account. Add a passkey to sign in anywhere.")
    }

    @MainActor
    func testProposalsAreKeptOnDiskForAnHour() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "proposals-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let proposal = Proposal(scheme: .email, kind: .addition, server: home.id, state: "q8Rz", email: "ada@example.com", account: "ada",
                                expires: now.addingTimeInterval(Proposals.lifetime))
        Proposals(directory: directory).remember(proposal, now: now)
        let reread = Proposals(directory: directory)
        XCTAssertEqual(reread.find("q8Rz", now: now.addingTimeInterval(3599)), proposal)
        XCTAssertNil(reread.find("q8Rz", now: now.addingTimeInterval(3601)))
        XCTAssertNil(reread.find(nil, now: now))
        reread.forget("q8Rz")
        XCTAssertNil(Proposals(directory: directory).find("q8Rz", now: now))
    }

    @MainActor
    func testOnlyEightProposalsAreKept() {
        let proposals = Proposals()
        for index in 0 ..< 9 {
            proposals.remember(Proposal(scheme: .external, kind: .signIn, server: home.id, state: "s\(index)", expires: now.addingTimeInterval(60)), now: now)
        }
        XCTAssertNil(proposals.find("s0", now: now))
        XCTAssertNotNil(proposals.find("s8", now: now))
    }

    @MainActor
    func testALinkWithOurStateGoesToItsProposalWhateverServerItNames() throws {
        let proposals = Proposals()
        let own = Proposal(scheme: .email, kind: .signIn, server: home.id, state: "q8Rz", expires: now.addingTimeInterval(60))
        proposals.remember(own, now: now)
        let link = try XCTUnwrap(ApronLink(URL(string: "https://link.apron.chat/#server=wss://elsewhere.example/ws&token=Hk41&state=q8Rz")!))
        XCTAssertEqual(LinkRoute(link, records: [home], proposal: proposals.find(link.state, now: now)), .proposal(own, token: "Hk41"))
        XCTAssertEqual(LinkUse(token: "Hk41", state: "q8Rz", server: home.url, proposals: proposals, now: now), .own(token: "Hk41", proposal: own))
        XCTAssertEqual(LinkUse(token: "Hk41", state: "other", server: home.url, proposals: proposals, now: now), .ask(token: "Hk41", server: home.url))
        let foreign = try XCTUnwrap(ApronLink(URL(string: "https://link.apron.chat/#server=wss://home.example/ws&token=Hk41&state=zzz")!))
        XCTAssertEqual(LinkRoute(foreign, records: [home], proposal: nil), .signIn(home, TokenPayload(token: "Hk41", server: home.url)))
    }

    func testASignInPageMustBeHTTPSOrLoopbackHTTP() {
        XCTAssertTrue(SignInPage.accepts(URL(string: "https://chat.example/sso?p=Qm7x")!))
        XCTAssertTrue(SignInPage.accepts(URL(string: "http://127.0.0.1:8080/sso")!))
        XCTAssertFalse(SignInPage.accepts(URL(string: "http://chat.example/sso")!))
        XCTAssertFalse(SignInPage.accepts(URL(string: "javascript:alert(1)")!))
    }

    func testThePageReturnsOnlyToAnAssociatedOrigin() {
        XCTAssertEqual(SignInPage.returnURL(origin: "https://home.example", domains: PasskeyDomains("home.example")), URL(string: "https://home.example/"))
        XCTAssertNil(SignInPage.returnURL(origin: "https://home.example", domains: .none))
        XCTAssertNil(SignInPage.returnURL(origin: "https://home.example:8443", domains: PasskeyDomains("home.example")))
    }

    func testExternalSignInParams() {
        XCTAssertEqual(SignIn.externalProposal(returnURL: URL(string: "https://home.example/")).params(agent: "a", state: "q8Rz").serialized(),
                       #"{"agent":"a","return_url":"https://home.example/","scheme":"external","state":"q8Rz"}"#)
        XCTAssertEqual(SignIn.link("Hk41").params(agent: "a", state: "x").serialized(), #"{"agent":"a","scheme":"token","token":"Hk41"}"#)
        XCTAssertEqual(SignIn.link("Hk41").method, "link")
        XCTAssertEqual(SignIn.ownLink("Hk41", scheme: .external).params(agent: "a", state: "x").serialized(),
                       #"{"agent":"a","scheme":"external","token":"Hk41"}"#)
    }

    func testTheConnectSheetOffersPasskeyAndExternalInTheServersOrder() throws {
        let server = try XCTUnwrap(ServerInfo(params: ["apron": 9, "auth": ["webauthn", "email", "external", "token", "guest"]]))
        XCTAssertEqual(ConnectForm.methods(offered: server), [.passkey, .email, .external, .token, .guest])
        var form = ConnectForm(record: ServerRecord(url: home.url, account: .init(userID: "ada", scheme: "webauthn")), mayWrite: true, prefill: nil)
        XCTAssertEqual(form.method, .passkey, "a saved passkey account signs in again by passkey")
        XCTAssertEqual(form.submitLabel(pendingEmail: nil, offered: server), "Sign In")
        form.passkeyMode = .register
        XCTAssertEqual(form.submitLabel(pendingEmail: nil, offered: server), "Create Account")
        let signInOnly = try XCTUnwrap(ServerInfo(params: ["apron": 9, "auth": ["webauthn", "token"], "signup": ["token"]]))
        XCTAssertEqual(form.passkeyAction(offered: signInOnly), .login, "passkeys here only sign in")
        form.method = .external
        XCTAssertEqual(form.submitLabel(pendingEmail: nil), "Continue")
        XCTAssertEqual(form.signIn(pendingEmail: nil, returnURL: nil), .externalProposal(returnURL: nil))
        let page = URL(string: "https://home.example/sso")!
        XCTAssertFalse(form.canSubmit(pendingEmail: nil, pendingPage: page), "the page's code first")
        form.code = " Qm7x-42 "
        XCTAssertEqual(form.signIn(pendingEmail: nil, pendingPage: page), .externalCode("Qm7x-42"))
    }

    func testAnAccountSavedBeforeAdditionsLoads() throws {
        let account = try JSONDecoder().decode(ServerRecord.Account.self, from: Data(#"{"userID":"ada","scheme":"token"}"#.utf8))
        XCTAssertEqual(account.methods, ["token"])
    }
}
