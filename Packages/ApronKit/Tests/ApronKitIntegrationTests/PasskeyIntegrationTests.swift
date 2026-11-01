import Foundation
import XCTest
@testable import ApronKit

/// The server side of the passkey ceremony against aprond, with `SoftwareAuthenticator` in the
/// platform's place. The record's origin is `https://localhost`, the shape iOS gives a native
/// app: the RP ID is `localhost` (aprond's default) and the origin carries no port.
@MainActor
final class PasskeyIntegrationTests: XCTestCase {
    private var servers: [Aprond] = []
    private var sessions: [ServerSession] = []

    override func tearDown() async throws {
        for session in sessions { await session.stop() }
        for server in servers { server.stop() }
    }

    private func startServer() async throws -> Aprond {
        // `--origin` admits the upgrade: on a real server the origin's host is the request's.
        let server = try await Aprond.start(["--webauthn.origin", "https://localhost", "--webauthn.origin", "https://web.example", "--origin", "https://localhost", "--origin", "https://web.example"])
        servers.append(server)
        return server
    }

    /// The server's address by name: the RP ID `localhost` must be its host (§4.10).
    private func localhost(_ server: Aprond) -> URL { URL(string: "ws://localhost:\(server.port)/ws")! }

    private func connected(_ server: Aprond, tokens: any TokenStore = InMemoryTokenStore()) async throws -> ServerSession {
        let record = ServerRecord(url: localhost(server), origin: "https://localhost")
        let environment = ServerSession.Environment(makeTransport: { WebSocketTransport(url: $0.url, origin: $0.origin) },
                                                    passkeyDomains: PasskeyDomains("localhost"))
        let session = ServerSession(record: record, tokens: tokens, environment: environment)
        sessions.append(session)
        session.start()
        try await waitFor("connected") { session.status == .signedOut }
        return session
    }

    func testCreateAnAccountWithAPasskeyThenSignInWithItElsewhere() async throws {
        let server = try await startServer()
        let first = try await connected(server)
        XCTAssertEqual(first.offersPasskeys.signIn, true, "aprond offers passkeys to the origin it was given")
        let device = SoftwareAuthenticator()
        let tokens = InMemoryTokenStore()
        let created = try await first.usePasskey(.register, name: "Ada", with: device)
        XCTAssertFalse(created.userID.hasPrefix("guest_"), created.userID)
        XCTAssertEqual(created.json["name"]?.stringValue, "Ada")
        XCTAssertEqual(first.record.account?.scheme, "webauthn")
        XCTAssertEqual(first.status, .signedIn)
        XCTAssertTrue(first.resumable, "the finish result carries a token")

        let other = try await connected(server, tokens: tokens)
        let signedIn = try await other.usePasskey(.login, with: device)
        XCTAssertEqual(signedIn.userID, created.userID)
        XCTAssertEqual(other.joinedRoomIDs, ["general"])

        await other.stop()
        other.start()
        try await waitFor("resumed with the passkey's token") { other.status == .signedIn }
        XCTAssertEqual(other.you?.userID, created.userID)
    }

    func testAPasskeyAddedToAnEmailAccountSignsInToIt() async throws {
        let server = try await startServer()
        let session = try await connected(server)
        _ = try await session.signIn(.emailProposal(address: "ada@example.com"))
        _ = try await session.signIn(.emailCode(try await server.emailCode(for: "ada@example.com")))
        let account = try XCTUnwrap(session.you?.userID)
        XCTAssertNil(session.wayBack, "an email account signs back in with email")

        let device = SoftwareAuthenticator()
        let same = try await session.usePasskey(.register, with: device)
        XCTAssertEqual(same.userID, account)
        XCTAssertEqual(session.record.account?.methods, ["email", "webauthn"])


        let elsewhere = try await connected(server)
        let signedIn = try await elsewhere.usePasskey(.login, with: device)
        XCTAssertEqual(signedIn.userID, account)
    }

    func testAPasskeySignsInFromTheOriginItWasMadeForOnly() async throws {
        let server = try await startServer()
        let first = try await connected(server)
        let device = SoftwareAuthenticator()
        _ = try await first.usePasskey(.register, name: "Ada", with: device)

        let record = ServerRecord(url: localhost(server), origin: "https://web.example")
        let environment = ServerSession.Environment(makeTransport: { WebSocketTransport(url: $0.url, origin: $0.origin) },
                                                    passkeyDomains: PasskeyDomains("localhost"))
        let wrongOrigin = ServerSession(record: record, tokens: InMemoryTokenStore(), environment: environment)
        sessions.append(wrongOrigin)
        wrongOrigin.start()
        try await waitFor("connected") { wrongOrigin.status == .signedOut }
        do {
            _ = try await wrongOrigin.usePasskey(.login, with: device)
            XCTFail("expected the origin check to refuse")
        } catch {
            XCTAssertEqual(errorText(error), "Passkeys for localhost sign in from https://localhost, but this server is set to the origin https://web.example. Change the origin under Name and Origin, then try again.")
        }
    }
}
