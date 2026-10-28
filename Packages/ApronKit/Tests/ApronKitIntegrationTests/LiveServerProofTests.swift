@testable import ApronKit
import Foundation
import XCTest

/// ServerSession against a deployed server, signing in with a token the web client's
/// `/add-device` issued. Skips unless `APRON_LIVE_TOKEN` is set, so the hermetic suite never
/// reaches the network. apron-server-rust's `tools/deploy/proof` drives it from a browser page
/// that holds the account, and checks there that the message posted here arrives.
///
/// - `APRON_LIVE_URL`: the WebSocket URL (default `wss://apron.farfield.systems/ws`)
/// - `APRON_LIVE_ORIGIN`: the origin the `/add-device` notice names
/// - `APRON_LIVE_TOKEN`: the token the notice names
/// - `APRON_LIVE_USER_ID`: the web account's `user_id`
/// - `APRON_LIVE_MESSAGE`: the text to post in `general`
@MainActor
final class LiveServerProofTests: XCTestCase {
    private struct Live {
        var url: URL
        var origin: String
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
        return Live(url: url, origin: try required("APRON_LIVE_ORIGIN"), token: token,
                    userID: try required("APRON_LIVE_USER_ID"), message: try required("APRON_LIVE_MESSAGE"))
    }

    /// A session whose upgrade sends `origin` as its `Origin` header, or none when it is nil.
    private func makeSession(_ live: Live, origin: String?) -> ServerSession {
        let environment = ServerSession.Environment(makeTransport: { record in
            WebSocketTransport(url: record.url, origin: origin)
        })
        let session = ServerSession(record: ServerRecord(url: live.url, origin: origin), tokens: InMemoryTokenStore(),
                                    environment: environment)
        sessions.append(session)
        return session
    }

    func testTheAddDeviceTokenSignsInAsTheWebAccountAndPosts() async throws {
        let live = try Self.live()
        XCTAssertEqual(ServerRecord(url: live.url).origin, live.origin, "a saved record's default origin is the notice's")
        let session = makeSession(live, origin: live.origin)
        session.start()
        try await waitFor("connected", timeout: .seconds(20)) { session.status == .signedOut }
        XCTAssertEqual(session.server?.apron, 9)
        XCTAssertTrue(Set(session.server?.auth ?? []).isSuperset(of: ["webauthn", "token"]), "\(session.server?.auth ?? [])")

        let outcome = try await session.signIn(.token(live.token))
        guard case .signedIn(let you) = outcome else { return XCTFail("expected a sign-in, got \(outcome)") }
        XCTAssertEqual(you.userID, live.userID)
        try await waitFor("the room list", timeout: .seconds(20)) { session.joinedRoomIDs.contains("general") }

        let posted = try await session.send(live.message, in: "general")
        XCTAssertNotNil(posted)
    }

    func testTheTokenIsRefusedFromAnyOtherOrigin() async throws {
        let live = try Self.live()
        let foreign = makeSession(live, origin: "https://ladle-proof.invalid")
        foreign.start()
        try await waitFor("the upgrade refused", timeout: .seconds(20)) { foreign.status == .stopped(.rejected(status: 403)) }

        // No Origin passes the upgrade, so this reaches the token's origin binding.
        let bare = makeSession(live, origin: nil)
        bare.start()
        try await waitFor("connected", timeout: .seconds(20)) { bare.status == .signedOut }
        do {
            let outcome = try await bare.signIn(.token(live.token))
            XCTFail("a token bound to \(live.origin) signed in without an Origin: \(outcome)")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, RPCError.Code.denied, error.message)
        }
        XCTAssertNil(bare.you)
    }
}
