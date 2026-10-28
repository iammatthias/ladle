@testable import ApronKit
import Foundation
import XCTest

/// ServerSession against a deployed server, signing in with a token the web client's
/// `/invite-device` issued. Skips unless `APRON_LIVE_TOKEN` is set, so the hermetic suite never
/// reaches the network. apron-server-rust's `tools/deploy/proof` drives it from a browser page
/// that holds the account, and checks there that the message posted here arrives.
///
/// A device token signs in from any origin, and with none, and its result carries no `token`:
/// the device keeps the one it presented.
///
/// - `APRON_LIVE_URL`: the WebSocket URL (default `wss://apron.farfield.systems/ws`)
/// - `APRON_LIVE_TOKEN`: the token the `/invite-device` notice names
/// - `APRON_LIVE_USER_ID`: the web account's `user_id`
/// - `APRON_LIVE_MESSAGE`: the text to post in `general`
@MainActor
final class LiveServerProofTests: XCTestCase {
    private struct Live {
        var url: URL
        var token: String
        var userID: String
        var message: String
    }

    private var sessions: [ServerSession] = []

    override func tearDown() async throws {
        for session in sessions { await session.stop() }
    }

    private static func live() throws -> Live {
        let environment = ProcessInfo.processInfo.environment
        guard let token = environment["APRON_LIVE_TOKEN"], !token.isEmpty else {
            throw XCTSkip("APRON_LIVE_TOKEN is unset; this test runs only against a live server")
        }
        func required(_ name: String) throws -> String {
            guard let value = environment[name], !value.isEmpty else { throw XCTSkip("\(name) is unset") }
            return value
        }
        let url = try XCTUnwrap(URL(string: environment["APRON_LIVE_URL"] ?? "wss://apron.farfield.systems/ws"))
        return Live(url: url, token: token, userID: try required("APRON_LIVE_USER_ID"), message: try required("APRON_LIVE_MESSAGE"))
    }

    /// A session whose upgrade sends `origin` as its `Origin` header, or none when it is nil.
    private func makeSession(_ live: Live, origin: String?, tokens: InMemoryTokenStore) -> ServerSession {
        let environment = ServerSession.Environment(makeTransport: { record in
            WebSocketTransport(url: record.url, origin: origin)
        })
        let session = ServerSession(record: ServerRecord(url: live.url, origin: origin), tokens: tokens, environment: environment)
        sessions.append(session)
        return session
    }

    /// Signs in with the device token and checks the account, and that no new token replaced it.
    private func signIn(_ live: Live, origin: String?) async throws -> ServerSession {
        let tokens = InMemoryTokenStore()
        let session = makeSession(live, origin: origin, tokens: tokens)
        session.start()
        try await waitFor("connected from \(origin ?? "no origin")", timeout: .seconds(20)) { session.status == .signedOut }
        let outcome = try await session.signIn(.token(live.token))
        guard case .signedIn(let you) = outcome else {
            XCTFail("expected a sign-in from \(origin ?? "no origin"), got \(outcome)")
            return session
        }
        XCTAssertEqual(you.userID, live.userID, "signed in from \(origin ?? "no origin")")
        XCTAssertEqual(try tokens.token(for: session.record.id), live.token, "the result carried no token to replace it")
        return session
    }

    func testTheInviteDeviceTokenSignsInAsTheWebAccountAndPosts() async throws {
        let live = try Self.live()
        let session = try await signIn(live, origin: ServerRecord(url: live.url).origin)
        XCTAssertEqual(session.server?.apron, 9)
        try await waitFor("the room list", timeout: .seconds(20)) { session.joinedRoomIDs.contains("general") }

        let posted = try await session.send(live.message, in: "general")
        XCTAssertNotNil(posted)
    }

    func testTheTokenSignsInFromAnyOriginAndWithNone() async throws {
        let live = try Self.live()
        _ = try await signIn(live, origin: "https://ladle-proof.invalid")
        _ = try await signIn(live, origin: nil)
    }
}
