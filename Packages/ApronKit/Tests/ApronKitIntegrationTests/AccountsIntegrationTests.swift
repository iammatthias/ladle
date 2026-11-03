@testable import ApronKit
import Foundation
import XCTest

/// Two accounts on one aprond, saved as two records in one `SessionStore`: each session is its
/// own account, one's message reaches the other, and their read cursors stay apart.
@MainActor
final class AccountsIntegrationTests: XCTestCase {
    private var server: Aprond?
    private var store: SessionStore?

    override func tearDown() async throws {
        for record in store?.records ?? [] { await store?.session(for: record.id)?.stop() }
        server?.stop()
    }

    func testTwoAccountsOnOneServerSignInSideBySideAndReadApart() async throws {
        let server = try await Aprond.start()
        self.server = server
        let tokens = InMemoryTokenStore()
        let environment = ServerSession.Environment(makeTransport: { WebSocketTransport(url: $0.url, origin: $0.origin) })
        let store = SessionStore(serverStore: nil, tokens: tokens, environment: environment)
        self.store = store
        let ada = store.add(ServerRecord(url: server.url, label: "Ada's"))
        let bot = store.add(ServerRecord(url: server.url, label: "Bot's"))
        XCTAssertEqual(store.accounts(on: server.url).map(\.id), [ada.record.id, bot.record.id])
        try await waitFor("both connected") { ada.status == .signedOut && bot.status == .signedOut }

        _ = try await ada.signIn(.emailProposal(address: "ada@example.com"))
        _ = try await ada.signIn(.emailCode(try await server.emailCode(for: "ada@example.com")))
        _ = try await bot.signIn(.emailProposal(address: "bot@example.com"))
        _ = try await bot.signIn(.emailCode(try await server.emailCode(for: "bot@example.com")))
        let adaID = try XCTUnwrap(ada.you?.userID)
        let botID = try XCTUnwrap(bot.you?.userID)
        XCTAssertNotEqual(adaID, botID)
        XCTAssertEqual(ada.record.account?.userID, adaID)
        XCTAssertEqual(bot.record.account?.userID, botID)
        let adaToken = try XCTUnwrap(tokens.token(for: ada.record.id))
        let botToken = try XCTUnwrap(tokens.token(for: bot.record.id))
        XCTAssertNotEqual(adaToken, botToken)
        XCTAssertEqual(store.liveSessions(for: server.url).map(\.record.id), [ada.record.id, bot.record.id])

        try await ada.open("general")
        try await bot.open("general")
        let sentID = try await ada.send("Specials are up", in: "general")
        let sent = try XCTUnwrap(sentID)
        try await waitFor("the bot's session holds Ada's message") { bot.store.message(sent) != nil }
        XCTAssertEqual(bot.store.message(sent)?.from.userID, adaID)
        XCTAssertEqual(bot.unreadCount(in: "general"), 1, "Ada's message is news to the bot")
        XCTAssertEqual(ada.unreadCount(in: "general"), 0, "and not to Ada")

        await bot.markRead("general", through: sent)
        XCTAssertEqual(bot.readPositions["general"], sent)
        XCTAssertEqual(bot.readCursors["general"], sent)
        XCTAssertNil(ada.readPositions["general"], "Ada's position is her own")
        try await waitFor("the server echoes the bot's cursor to the bot alone") { bot.readCursors["general"] == sent }
        XCTAssertNotEqual(ada.readCursors["general"], sent)

        await store.remove(bot.record.id)
        XCTAssertEqual(store.records.map(\.id), [ada.record.id])
        XCTAssertNil(try tokens.token(for: bot.record.id))
        XCTAssertEqual(try tokens.token(for: ada.record.id), adaToken)
        XCTAssertEqual(ada.status, .signedIn, "removing the bot's record leaves Ada connected")
    }
}
