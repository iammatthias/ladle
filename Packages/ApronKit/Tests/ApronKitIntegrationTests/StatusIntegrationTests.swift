@testable import ApronKit
import Foundation
import XCTest

/// `status` (§4.5) against the real Rust server: pausing and muting, seen on another device.
@MainActor
final class StatusIntegrationTests: XCTestCase {
    private var servers: [Aprond] = []
    private var sessions: [ServerSession] = []

    override func tearDown() async throws {
        for session in sessions { await session.stop() }
        for server in servers { server.stop() }
    }

    private func started(_ arguments: [String] = []) async throws -> Aprond {
        let server = try await Aprond.start(arguments)
        servers.append(server)
        return server
    }

    /// Ada's account by email; `sameAs` signs another device into it with that device's token.
    private func signedIn(_ server: Aprond, sameAs device: ServerSession? = nil) async throws -> ServerSession {
        let environment = ServerSession.Environment(makeTransport: { WebSocketTransport(url: $0.url, origin: $0.origin) })
        let tokens = InMemoryTokenStore()
        let session = ServerSession(record: ServerRecord(url: server.url), tokens: tokens, environment: environment)
        sessions.append(session)
        tokenStores[ObjectIdentifier(session)] = tokens
        session.start()
        try await waitFor("connected") { session.status == .signedOut }
        if let device, let token = try tokenStores[ObjectIdentifier(device)]?.token(for: device.record.id) {
            _ = try await session.signIn(.token(token))
        } else {
            _ = try await session.signIn(.emailProposal(address: "ada@example.com"))
            _ = try await session.signIn(.emailCode(try await server.emailCode(for: "ada@example.com")))
        }
        try await waitFor("the room list") { session.joinedRoomIDs.contains("general") }
        return session
    }

    private var tokenStores: [ObjectIdentifier: InMemoryTokenStore] = [:]

    func testAPauseAndARoomMuteShowOnEveryDeviceAndEnd() async throws {
        let server = try await started()
        let phone = try await signedIn(server)
        let laptop = try await signedIn(server, sameAs: phone)
        XCTAssertTrue(phone.mayMute, "aprond has capability status")

        try await phone.setPause(.at(Date().addingTimeInterval(3600)))
        try await waitFor("paused on the phone") { phone.pause != nil }
        try await waitFor("paused set elsewhere shows") { laptop.pause != nil }
        guard case .at(let end) = laptop.pause else { return XCTFail("a timed pause: \(String(describing: laptop.pause))") }
        XCTAssertEqual(end.timeIntervalSinceNow, 3600, accuracy: 10)
        XCTAssertTrue(laptop.profileLine?.hasPrefix("Paused until ") == true, laptop.profileLine ?? "")

        try await phone.setMute("general", .untilChanged)
        try await waitFor("general muted elsewhere") { laptop.mute(of: "general") == .own(.untilChanged) }

        try await laptop.setMute("general", nil)
        try await laptop.setPause(nil)
        try await waitFor("unmuted and resumed on the phone") { phone.mute(of: "general") == nil && phone.pause == nil }
    }

    func testAPauseInEffectComesBackWithTheNextSignIn() async throws {
        let server = try await started()
        let phone = try await signedIn(server)
        try await phone.setPause(.untilChanged)
        try await phone.setMute("general", .at(Date().addingTimeInterval(600)))
        try await waitFor("both applied") { phone.pause != nil && phone.mute(of: "general") != nil }

        let tablet = try await signedIn(server, sameAs: phone)
        try await waitFor("the server sends the mutes in effect after sign-in") {
            tablet.pause == .untilChanged && tablet.mute(of: "general") != nil
        }
    }

    func testOthersSeeYouIdleUntilYouAreBack() async throws {
        let server = try await started(["--limit.status-coalesce-seconds", "0"])
        let ada = try await signedIn(server)
        let environment = ServerSession.Environment(makeTransport: { WebSocketTransport(url: $0.url, origin: $0.origin) })
        let admin = ServerSession(record: ServerRecord(url: server.url), tokens: InMemoryTokenStore(), environment: environment)
        sessions.append(admin)
        admin.start()
        try await waitFor("admin connected") { admin.status == .signedOut }
        try await admin.signIn(.token(server.adminToken))
        let adaID = try XCTUnwrap(ada.you?.userID)
        try await waitFor("Ada online to the admin") { admin.presence(of: adaID) == .online }

        ada.setIdle(true, inputAt: Date().addingTimeInterval(-30))
        try await waitFor("Ada idle to the admin", timeout: .seconds(10)) { admin.presence(of: adaID) == .idle }
        ada.setIdle(false, inputAt: Date())
        try await waitFor("Ada back", timeout: .seconds(10)) { admin.presence(of: adaID) == .online }
    }

    func testAMuteOfARoomYouCannotSeeIsRefusedWithTheServersWords() async throws {
        let server = try await started()
        let phone = try await signedIn(server)
        do {
            try await phone.setMute("nowhere", .untilChanged)
            XCTFail("refused")
        } catch let error as RPCError {
            XCTAssertEqual(error.message, "Unknown room \"nowhere\"")
        }
        XCTAssertNil(phone.mute(of: "nowhere"))
    }
}
