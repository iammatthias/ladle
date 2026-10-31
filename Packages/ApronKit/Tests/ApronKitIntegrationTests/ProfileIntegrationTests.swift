@testable import ApronKit
import Foundation
import XCTest

/// Your profile and status (`me`, §3.3.2, §4.5) and the profile card's Add to room, against the
/// real Rust server.
@MainActor
final class ProfileIntegrationTests: XCTestCase {
    private var servers: [Aprond] = []
    private var sessions: [ServerSession] = []

    override func tearDown() async throws {
        for session in sessions { await session.stop() }
        for server in servers { server.stop() }
    }

    private func signedIn(_ server: Aprond, email: String) async throws -> ServerSession {
        let environment = ServerSession.Environment(makeTransport: { WebSocketTransport(url: $0.url, origin: $0.origin) })
        let session = ServerSession(record: ServerRecord(url: server.url), tokens: InMemoryTokenStore(), environment: environment)
        sessions.append(session)
        session.start()
        try await waitFor("connected") { session.status == .signedOut }
        _ = try await session.signIn(.emailProposal(address: email))
        _ = try await session.signIn(.emailCode(try await server.emailCode(for: email)))
        return session
    }

    func testAnAccountSavesItsNameAndBioAndChoosesItsStatus() async throws {
        let server = try await Aprond.start()
        servers.append(server)
        let session = try await signedIn(server, email: "ada@example.com")
        XCTAssertTrue(session.keepsBio, "aprond keeps any ext key")
        XCTAssertTrue(session.maySetStatus)

        var form = ProfileForm(you: session.you)
        form.name = "Ada Lovelace"
        form.bio = "Soup,\tmostly.\u{202E}"
        let saved = await session.save(form)
        XCTAssertEqual(saved.outcome, .saved)
        XCTAssertNil(saved.bioError)
        XCTAssertEqual(session.you?.json["name"]?.stringValue, "Ada Lovelace")
        XCTAssertEqual(Bio.of(session.you?.json), "Soup, mostly.")
        XCTAssertEqual(session.record.account?.name, "Ada Lovelace")

        let optional = Set(session.server?.status ?? [])
        for status in ["dnd", "invisible"] {
            let answer = await session.chooseStatus(status)
            if optional.contains(status) {
                XCTAssertNil(answer, "\(status) is listed in server.status, so it sticks")
                XCTAssertEqual(session.chosenStatus, status)
            } else {
                XCTAssertEqual(answer?.text, "Your status is None.")
            }
        }
        let none = await session.chooseStatus("")
        XCTAssertNil(none)
        XCTAssertEqual(session.chosenStatus, "")
        let online = await session.chooseStatus("online")
        XCTAssertNil(online)
        XCTAssertEqual(session.chosenStatus, "online")

        let removed = try await session.removeAvatar()
        XCTAssertTrue(removed)

        var cleared = ProfileForm(you: session.you)
        cleared.bio = ""
        let without = await session.save(cleared)
        XCTAssertEqual(without.outcome, .saved)
        XCTAssertNil(Bio.of(session.you?.json))
    }

    func testAGuestsNewNameIsDeclinedAndTheOldOneStays() async throws {
        let server = try await Aprond.start()
        servers.append(server)
        let environment = ServerSession.Environment(makeTransport: { WebSocketTransport(url: $0.url, origin: $0.origin) })
        let session = ServerSession(record: ServerRecord(url: server.url), tokens: InMemoryTokenStore(), environment: environment)
        sessions.append(session)
        session.start()
        try await waitFor("connected") { session.status == .signedOut }
        try await session.signIn(.guest(name: nil))
        let name = session.you?.json["name"]?.stringValue

        var form = ProfileForm(you: session.you)
        form.name = "Not a guest"
        let declined = await session.save(form)
        guard case .declined(let note) = declined.outcome else { return XCTFail("expected a refusal, got \(declined.outcome)") }
        XCTAssertTrue(note.hasPrefix("The server declined this name ("), note)
        XCTAssertEqual(session.you?.json["name"]?.stringValue, name)
    }
}
