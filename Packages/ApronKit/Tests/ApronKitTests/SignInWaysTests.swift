import Foundation
import Synchronization
import XCTest
@testable import ApronKit

/// A passkey sheet that hands back a fixed credential, and records what it was asked.
@MainActor
final class StubAuthenticator: PasskeyAuthenticator {
    var asked: [(PasskeyChallenge, String)] = []
    let credential: PasskeyCredential

    init(_ credential: PasskeyCredential) { self.credential = credential }

    func credential(for challenge: PasskeyChallenge, name: String) async throws -> PasskeyCredential {
        asked.append((challenge, name))
        return credential
    }
}

@MainActor
final class SignInWaysTests: XCTestCase {
    static let greeting: JSONValue = ["method": "server", "params": [
        "apron": 9, "auth": ["webauthn", "email", "external", "token", "guest"], "capabilities": ["history", "rooms"],
    ]]
    let record = ServerRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, url: URL(string: "wss://chat.example/ws")!)
    let tokens = InMemoryTokenStore()
    let made = Transports()
    let proposals = Proposals()
    let assertion = PasskeyCredential.assertion(id: Data([1]), clientDataJSON: Data("{}".utf8), authenticatorData: Data([2]),
                                                signature: Data([3]), userHandle: Data([4]), attachment: .platform)
    var session: ServerSession!

    override func setUp() async throws {
        session = makeSession(record)
    }

    override func tearDown() async throws {
        await session.stop()
    }

    private func makeSession(_ record: ServerRecord) -> ServerSession {
        let counter = Mutex(0)
        let made = made
        let environment = ServerSession.Environment(
            makeTransport: { _ in
                let transport = FakeTransport()
                made.made.withLock { $0.append(transport) }
                Task { await transport.deliver(SignInWaysTests.greeting) }
                return transport
            },
            sleep: { _ in try await Task.sleep(for: .milliseconds(10)) },
            jitter: { 1 },
            makeRequestID: { counter.withLock { $0 += 1; return "c\($0)" } },
            makeState: { "q8Rz" },
            agent: "ladle-ios/test",
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            passkeyDomains: PasskeyDomains("chat.example")
        )
        return ServerSession(record: record, tokens: tokens, proposals: proposals, environment: environment)
    }

    private func transport(_ index: Int) async -> FakeTransport {
        await eventually("transport \(index)") { made.made.withLock { $0.count > index } }
        return made.made.withLock { $0[index] }
    }

    private func frames(_ transport: FakeTransport, count: Int) async -> [String] {
        await eventually("\(count) frames") { await transport.sentLog.count >= count }
        return await Array(transport.sentLog.prefix(count))
    }

    func testAPasskeySignsInWithBothStepsOnOneConnection() async throws {
        session.start()
        let socket = await transport(0)
        await eventually("signed out") { session.status == .signedOut }
        let sheet = StubAuthenticator(assertion)
        let signIn = Task { try await session.usePasskey(.login, with: sheet) }
        let begin = await frames(socket, count: 1)
        XCTAssertEqual(begin[0], #"{"id":"c1","method":"auth","params":{"action":"login","agent":"ladle-ios/test","scheme":"webauthn","step":"begin"}}"#)
        await socket.deliver(["id": "c1", "result": ["challenge_id": "ch1", "public_key": ["challenge": "AAEC", "rpId": "chat.example", "userVerification": "required"]]])
        let finish = await frames(socket, count: 3)
        XCTAssertEqual(finish[1], #"{"id":"c2","method":"auth","params":{"action":"login","agent":"ladle-ios/test","challenge_id":"ch1","credential":{"authenticatorAttachment":"platform","clientExtensionResults":{},"id":"AQ","rawId":"AQ","response":{"authenticatorData":"Ag","clientDataJSON":"e30","signature":"Aw","userHandle":"BA"},"type":"public-key"},"scheme":"webauthn","step":"finish"}}"#)
        XCTAssertEqual(finish[2], #"{"id":"c3","method":"room_list","params":{"filter":"joined","members":true}}"#)
        await socket.deliver(["id": "c2", "result": ["you": ["user_id": "ada", "name": "Ada"], "token": "st_1"]])
        await socket.deliver(["id": "c3", "result": ["joined": []]])
        let you = try await signIn.value
        XCTAssertEqual(you.userID, "ada")
        XCTAssertEqual(sheet.asked.map(\.0.rpID), ["chat.example"])
        XCTAssertEqual(session.record.account, ServerRecord.Account(userID: "ada", name: "Ada", scheme: "webauthn"))
        XCTAssertEqual(try tokens.token(for: record.id), "st_1")
        XCTAssertNil(session.wayBack, "a passkey account has a way back")
    }

    func testAForeignRelyingPartyNeverReachesTheSheet() async throws {
        session.start()
        let socket = await transport(0)
        await eventually("signed out") { session.status == .signedOut }
        let sheet = StubAuthenticator(assertion)
        let signIn = Task { try await session.usePasskey(.login, with: sheet) }
        _ = await frames(socket, count: 1)
        await socket.deliver(["id": "c1", "result": ["challenge_id": "ch1", "public_key": ["challenge": "AAEC", "rpId": "apron.chat"]]])
        do {
            _ = try await signIn.value
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(errorText(error), "This server (chat.example) asked for a passkey for apron.chat, which is not its own.")
        }
        XCTAssertTrue(sheet.asked.isEmpty)
    }

    func testARefusedTokenHoldsAPasskeyAccountForATap() async throws {
        var saved = record
        saved.account = ServerRecord.Account(userID: "ada", name: "Ada", scheme: "webauthn")
        try tokens.setToken("st_old", for: saved.id)
        session = makeSession(saved)
        session.start()
        let socket = await transport(0)
        _ = await frames(socket, count: 2)
        await socket.deliver(["id": "c1", "error": ["code": -32001, "message": "Session expired"]])
        await eventually("held") { session.passkeyHold }
        XCTAssertEqual(session.signInNeeded, "Session expired")
        XCTAssertEqual(session.heldAccount?.userID, "ada")
    }

    func testATokenThatExpiresWhileSignedInHoldsAPasskeyAccountOnReconnect() async throws {
        var saved = record
        saved.account = ServerRecord.Account(userID: "ada", name: "Ada", scheme: "webauthn")
        try tokens.setToken("st_1", for: saved.id)
        session = makeSession(saved)
        session.start()
        let first = await transport(0)
        _ = await frames(first, count: 2)
        await first.deliver(["id": "c1", "result": ["you": ["user_id": "ada", "name": "Ada"]]])
        await first.deliver(["id": "c2", "result": ["joined": []]])
        await eventually("signed in") { session.status == .signedIn }
        XCTAssertFalse(session.passkeyHold)

        await first.close(code: 1000, reason: "")
        let second = await transport(1)
        XCTAssertEqual(session.record.account?.scheme, "webauthn", "resuming keeps how the account signed in")
        _ = await frames(second, count: 2)
        await second.deliver(["id": "c3", "error": ["code": -32001, "message": "Session expired"]])
        await eventually("held after the resume is refused") { session.passkeyHold }
        XCTAssertEqual(session.signInNeeded, "Session expired")
    }

    func testAnExternalSignInWithoutAReturnShowsThePageAndTakesItsCode() async throws {
        session.start()
        let socket = await transport(0)
        await eventually("signed out") { session.status == .signedOut }
        let propose = Task { try await session.signIn(.externalProposal(returnURL: nil)) }
        let sent = await frames(socket, count: 1)
        XCTAssertEqual(sent[0], #"{"id":"c1","method":"auth","params":{"agent":"ladle-ios/test","scheme":"external","state":"q8Rz"}}"#)
        XCTAssertEqual(proposals.find("q8Rz", now: Date(timeIntervalSince1970: 1_800_000_000))?.kind, .signIn)
        await socket.deliver(["id": "c1", "result": ["url": "https://chat.example/sso?p=Qm7x"]])
        let page = try await propose.value
        XCTAssertEqual(page, .page(URL(string: "https://chat.example/sso?p=Qm7x")!, returns: false))
        XCTAssertEqual(session.pendingPage, URL(string: "https://chat.example/sso?p=Qm7x"))

        let approve = Task { try await session.signIn(.externalCode("Qm7x-42")) }
        let approval = await frames(socket, count: 3)
        XCTAssertEqual(approval[1], #"{"id":"c2","method":"auth","params":{"agent":"ladle-ios/test","scheme":"external","token":"Qm7x-42"}}"#)
        await socket.deliver(["id": "c2", "result": ["you": ["user_id": "ada"], "token": "st_1"]])
        await socket.deliver(["id": "c3", "result": ["joined": []]])
        _ = try await approve.value
        XCTAssertNil(session.pendingPage)
        XCTAssertNil(proposals.find("q8Rz", now: Date(timeIntervalSince1970: 1_800_000_000)), "approval used the proposal up")
        XCTAssertEqual(session.record.account?.scheme, "external")
    }

    func testAnExternalPageThatIsNotHTTPSIsRefused() async throws {
        session.start()
        let socket = await transport(0)
        await eventually("signed out") { session.status == .signedOut }
        let propose = Task { try await session.signIn(.externalProposal(returnURL: nil)) }
        _ = await frames(socket, count: 1)
        await socket.deliver(["id": "c1", "result": ["url": "javascript:alert(1)"]])
        do {
            _ = try await propose.value
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(errorText(error), "The server's sign-in page isn't a secure web address, so Ladle won't open it.")
        }
        XCTAssertNil(session.pendingPage)
    }

    func testAnEmailIsAddedOnTheSignedInConnectionAndEndsTheNudge() async throws {
        session.start()
        let socket = await transport(0)
        await eventually("signed out") { session.status == .signedOut }
        let signIn = Task { try await session.signIn(.token("apron_invite_x")) }
        _ = await frames(socket, count: 2)
        await socket.deliver(["id": "c1", "result": ["you": ["user_id": "ada", "name": "Ada"]]])
        await socket.deliver(["id": "c2", "result": ["joined": []]])
        _ = try await signIn.value
        XCTAssertEqual(session.wayBack, [.webauthn, .email, .external])

        let propose = Task { try await session.proposeAddition(.email, email: " ada@example.com ") }
        let sent = await frames(socket, count: 3)
        XCTAssertEqual(sent[2], #"{"id":"c3","method":"auth","params":{"agent":"ladle-ios/test","email":"ada@example.com","scheme":"email","state":"q8Rz"}}"#)
        await socket.deliver(["id": "c3", "result": [:]])
        let proposed = try await propose.value
        XCTAssertEqual(proposed, .codeSent(to: "ada@example.com"))
        XCTAssertEqual(proposals.find("q8Rz", now: Date(timeIntervalSince1970: 1_800_000_000))?.account, "ada")

        let approve = Task { try await session.approveAddition(code: "418092") }
        let approval = await frames(socket, count: 4)
        XCTAssertEqual(approval[3], #"{"id":"c4","method":"auth","params":{"scheme":"email","token":"418092"}}"#)
        await socket.deliver(["id": "c4", "result": [:]])
        try await approve.value
        XCTAssertEqual(session.record.account?.methods, ["token", "email"])
        XCTAssertNil(session.wayBack)
        XCTAssertEqual(session.status, .signedIn)
    }

    func testAPasskeyAddedToAnAccountKeepsHowItSignedIn() async throws {
        session.start()
        let socket = await transport(0)
        await eventually("signed out") { session.status == .signedOut }
        let signIn = Task { try await session.signIn(.token("apron_invite_x")) }
        _ = await frames(socket, count: 2)
        await socket.deliver(["id": "c1", "result": ["you": ["user_id": "ada", "name": "Ada"]]])
        await socket.deliver(["id": "c2", "result": ["joined": []]])
        _ = try await signIn.value

        let sheet = StubAuthenticator(.registration(id: Data([9]), clientDataJSON: Data("{}".utf8), attestationObject: Data([0xA0]), attachment: nil))
        let add = Task { try await session.usePasskey(.register, with: sheet) }
        let begin = await frames(socket, count: 3)
        XCTAssertEqual(begin[2], #"{"id":"c3","method":"auth","params":{"action":"register","agent":"ladle-ios/test","scheme":"webauthn","step":"begin"}}"#)
        await socket.deliver(["id": "c3", "result": ["challenge_id": "ch2", "public_key": [
            "challenge": "AAEC", "rp": ["id": "chat.example"], "user": ["id": "aA", "name": "ada", "displayName": "Ada"],
        ]]])
        let finish = await frames(socket, count: 4)
        XCTAssertTrue(finish[3].contains(#""step":"finish""#))
        await socket.deliver(["id": "c4", "result": ["you": ["user_id": "ada", "name": "Ada"], "token": "st_2"]])
        _ = try await add.value
        XCTAssertEqual(sheet.asked.map(\.1), ["Ada"], "labelled with the account's name")
        XCTAssertEqual(session.record.account?.methods, ["token", "webauthn"])
        XCTAssertEqual(try tokens.token(for: record.id), "st_2")
        let sentCount = await socket.sentLog.count
        XCTAssertEqual(sentCount, 4, "no room listing: adding a passkey signs no one in")
    }
}
