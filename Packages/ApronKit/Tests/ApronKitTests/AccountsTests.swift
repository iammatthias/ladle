import XCTest
@testable import ApronKit

/// Two accounts on one server are two records at one URL: each has its own session, token,
/// read positions, drafts and kept history, and removing one leaves the other's alone.
@MainActor
final class AccountsTests: XCTestCase {
    private let url = URL(string: "wss://home.example/ws")!
    private let samID = UUID(uuidString: "6C61646C-0000-4000-8000-0000000000A1")!
    private let sousID = UUID(uuidString: "6C61646C-0000-4000-8000-0000000000A2")!
    private let awayID = UUID(uuidString: "6C61646C-0000-4000-8000-0000000000A3")!

    private static let greeting: JSONValue = [
        "apron": 10, "auth": ["token", "guest"], "agent": "aprond/0.10", "title": "Home",
        "capabilities": ["history", "rooms", "status", "activity"],
    ]

    private static func script(you: JSONValue, token: String) -> PreviewServer.Script {
        var script = PreviewServer.Script(
            greeting: greeting, you: you,
            roomList: ["joined": [["room_id": "general", "log_id": "1", "title": "general", "latest_log_id": "1", "history_log_id": "1"]]],
            histories: ["general": ["messages": [], "more": false]], readCursors: [:])
        script.token = token
        return script
    }

    private var tokens = InMemoryTokenStore()
    private var history = InMemoryHistoryFiles()
    private var store: SessionStore!

    /// Sam and the Sous Chef bot on home, both saved with a token, and Sam alone on another server.
    private func makeStore() async throws -> (sam: ServerSession, sous: ServerSession) {
        let scripts = [
            samID: Self.script(you: ["user_id": "sam", "name": "Sam"], token: "tok-sam"),
            sousID: Self.script(you: ["user_id": "sous", "name": "Sous Chef"], token: "tok-sous"),
            awayID: Self.script(you: ["user_id": "sam", "name": "Sam"], token: "tok-away"),
        ]
        let environment = ServerSession.Environment(makeTransport: { PreviewServer(script: scripts[$0.id]!) },
                                                    sleep: { _ in try await Task.sleep(for: .seconds(3600)) }, jitter: { 1 })
        store = SessionStore(serverStore: nil, tokens: tokens, environment: environment, historyFiles: history)
        for (id, token) in [(samID, "tok-sam"), (sousID, "tok-sous"), (awayID, "tok-away")] { try tokens.setToken(token, for: id) }
        let sam = store.add(ServerRecord(id: samID, url: url, account: .init(userID: "sam", name: "Sam", scheme: "token")))
        let sous = store.add(ServerRecord(id: sousID, url: url, account: .init(userID: "sous", name: "Sous Chef", scheme: "token")))
        store.add(ServerRecord(id: awayID, url: URL(string: "wss://away.example/ws")!, label: "Away",
                               account: .init(userID: "sam", name: "Sam", scheme: "token")))
        for session in [sam, sous] {
            await eventually { session.status == .signedIn && session.joinedRoomIDs.contains("general") }
        }
        return (sam, sous)
    }

    private func eventually(_ condition: () -> Bool) async {
        for _ in 0 ..< 500 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    override func tearDown() async throws {
        for record in store?.records ?? [] { await store.session(for: record.id)?.stop() }
    }

    func testTwoAccountsOnOneServerAreTwoRecordsWithTheirOwnSessionsAndTokens() async throws {
        let (sam, sous) = try await makeStore()
        XCTAssertEqual(store.accounts(on: url).map(\.id), [samID, sousID])
        XCTAssertEqual(store.accounts(on: URL(string: "wss://away.example/ws")!).map(\.id), [awayID])
        XCTAssertEqual(sam.you?.userID, "sam")
        XCTAssertEqual(sous.you?.userID, "sous")
        XCTAssertEqual(try tokens.token(for: samID), "tok-sam")
        XCTAssertEqual(try tokens.token(for: sousID), "tok-sous")
        XCTAssertEqual(store.heading(for: sam), "Home · \u{2068}Sam\u{2069}")
        XCTAssertEqual(store.heading(for: sous), "Home · \u{2068}Sous Chef\u{2069}")
        XCTAssertEqual(store.heading(for: store.session(for: awayID)!), "Away", "alone on its server, the account is not named")
        XCTAssertEqual(sam.accountName, "Sam")
        XCTAssertEqual(store.liveSessions(for: url).map(\.record.id), [samID, sousID])
    }

    func testEachAccountReadsAndDraftsOnItsOwn() async throws {
        let (sam, sous) = try await makeStore()
        await sam.markRead("general", through: LogID("40")!)
        XCTAssertEqual(sam.readPositions, ["general": LogID("40")!])
        XCTAssertEqual(sous.readPositions, [:])
        await sous.markRead("general", through: LogID("7")!)
        XCTAssertEqual(sous.readPositions, ["general": LogID("7")!])
        XCTAssertEqual(sam.readPositions, ["general": LogID("40")!])

        store.drafts[DraftKey(server: samID, roomID: "general")] = ComposerDraft(field: DraftField(text: "from sam"))
        store.drafts[DraftKey(server: sousID, roomID: "general")] = ComposerDraft(field: DraftField(text: "from the bot"))
        XCTAssertEqual(store.drafts[DraftKey(server: samID, roomID: "general")].field.text, "from sam")
        XCTAssertEqual(store.drafts[DraftKey(server: sousID, roomID: "general")].field.text, "from the bot")

        await sam.flushKept()
        await sous.flushKept()
        XCTAssertEqual(Set(history.sizes().keys), [KeptAccount(server: samID, userID: "sam"), KeptAccount(server: sousID, userID: "sous")])
    }

    func testRemovingOneAccountLeavesTheOthersFiles() async throws {
        let (sam, sous) = try await makeStore()
        await sam.markRead("general", through: LogID("40")!)
        await sous.markRead("general", through: LogID("7")!)
        store.drafts[DraftKey(server: samID, roomID: "general")] = ComposerDraft(field: DraftField(text: "from sam"))
        store.drafts[DraftKey(server: sousID, roomID: "general")] = ComposerDraft(field: DraftField(text: "from the bot"))
        await sam.flushKept()
        await sous.flushKept()
        let samNotify = NotificationSettings.account(server: samID, userID: "sam", guest: false)
        let sousNotify = NotificationSettings.account(server: sousID, userID: "sous", guest: false)
        store.alerts.settings.set(.joined, true, for: samNotify)
        store.alerts.settings.set(.joined, true, for: sousNotify)

        await store.remove(samID)

        XCTAssertEqual(store.records.map(\.id), [sousID, awayID])
        XCTAssertNil(store.session(for: samID))
        XCTAssertNil(try tokens.token(for: samID))
        XCTAssertEqual(try tokens.token(for: sousID), "tok-sous")
        XCTAssertEqual(store.drafts[DraftKey(server: samID, roomID: "general")].field.text, "")
        XCTAssertEqual(store.drafts[DraftKey(server: sousID, roomID: "general")].field.text, "from the bot")
        XCTAssertEqual(Set(history.sizes().keys), [KeptAccount(server: sousID, userID: "sous")])
        XCTAssertEqual(store.alerts.settings.scopes.keys.sorted(), [sousNotify])
        XCTAssertEqual(sous.readPositions, ["general": LogID("7")!])
        XCTAssertEqual(store.heading(for: sous), "Home", "alone now, so the server's name is enough")
        XCTAssertEqual(store.liveSessions(for: url).map(\.record.id), [sousID])
    }

    func testReadPositionsOfARemovedRecordGoWhileTheOthersStay() throws {
        let directory = URL.temporaryDirectory.appending(path: "positions-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = FileReadPositionStore(directory: directory)
        file.advance("general", to: LogID("40")!, server: samID, user: "sam")
        file.advance("general", to: LogID("7")!, server: sousID, user: "sous")
        file.remove(server: samID)
        XCTAssertEqual(try String(contentsOf: file.fileURL, encoding: .utf8), """
        {
          "6C61646C-0000-4000-8000-0000000000A2" : {
            "sous" : {
              "general" : "7"
            }
          }
        }
        """)
        XCTAssertEqual(file.positions(server: samID, user: "sam"), [:])
        XCTAssertEqual(file.positions(server: sousID, user: "sous"), ["general": LogID("7")!])

        let memory = InMemoryReadPositionStore()
        memory.advance("general", to: LogID("40")!, server: samID, user: "sam")
        memory.advance("general", to: LogID("7")!, server: sousID, user: "sous")
        memory.remove(server: samID)
        XCTAssertEqual(memory.positions(server: samID, user: "sam"), [:])
        XCTAssertEqual(memory.positions(server: sousID, user: "sous"), ["general": LogID("7")!])
    }
}
