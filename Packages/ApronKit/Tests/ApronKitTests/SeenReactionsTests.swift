import Synchronization
import XCTest
@testable import ApronKit

/// New reactions to your own messages: each room's baseline at first sight, each message's mark
/// once it is seen, kept per account beside `servers.json`.
@MainActor
final class SeenReactionsTests: XCTestCase {
    let record = ServerRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!, url: URL(string: "wss://chat.example/ws")!)
    let transports = Transports()
    var seen = SeenReactions()
    var session: ServerSession!
    var socket: FakeTransport!

    override func setUp() async throws {
        seen = SeenReactions()
        session = makeSession(seen)
    }

    override func tearDown() async throws {
        await session.stop()
    }

    private func makeSession(_ seen: SeenReactions) -> ServerSession {
        let counter = Mutex(0)
        let transports = transports
        let environment = ServerSession.Environment(makeTransport: { _ in transports.next() },
                                                    makeRequestID: { counter.withLock { $0 += 1; return "c\($0)" } })
        return ServerSession(record: record, tokens: InMemoryTokenStore(), seenReactions: seen, environment: environment)
    }

    /// Signs in as Ada with #general listed at `latest`.
    private func signIn(latest: String = "100") async throws {
        socket = FakeTransport()
        transports.queued.withLock { $0.append(socket) }
        await socket.deliver(ServerSessionTests.greeting)
        session.start()
        await eventually("signed out") { session.status == .signedOut }
        let signIn = Task { try await session.signIn(.guest(name: nil)) }
        await eventually("auth sent") { await socket.sentLog.count == 2 }
        await socket.deliver(["id": "c1", "result": ["you": ["user_id": "ada", "name": "Ada"], "token": "t1"]])
        await socket.deliver(["id": "c2", "result": ["joined": [["room_id": "general", "log_id": "10", "title": "General",
                                                                  "latest_log_id": .string(latest), "history_log_id": "1"]]]])
        _ = try await signIn.value
    }

    private func post(_ id: String, from user: String) async {
        await socket.deliver(["method": "message", "params": [
            "message_id": .string(id), "log_id": .string(id), "room_id": "general", "from": ["user_id": .string(user)],
            "body": ["text": "hi", "format": "plain"],
        ]])
    }

    private func react(_ logID: String, on messageID: String, from user: String, _ emojis: [String]) async {
        await socket.deliver(["method": "reactions", "params": [
            "log_id": .string(logID), "message_id": .string(messageID), "room_id": "general",
            "reactions": [["from": ["user_id": .string(user)], "emojis": .array(emojis.map(JSONValue.string))]],
        ]])
    }

    /// The live frames are applied in order: waits until the one at `logID` is in.
    private func applied(_ logID: String, on messageID: String) async {
        await eventually("reaction \(logID)") {
            session.store.reactionSets(on: LogID(messageID)!).contains { $0.logID == LogID(logID)! }
        }
    }

    private var unseen: [UnseenReactions] { session.unseenReactions(in: "general") }

    private func unseen(_ pairs: [(String, Int)]) -> [UnseenReactions] {
        pairs.map { UnseenReactions(messageID: LogID($0.0)!, count: $0.1) }
    }

    func testOthersReactionsToYourMessagesAreNewOldestFirstNotYoursRemovedOrOnOthers() async throws {
        try await signIn()
        await post("101", from: "ada")
        await post("102", from: "bob")
        await post("103", from: "ada")
        await react("104", on: "101", from: "bob", ["👍"])
        await react("105", on: "103", from: "carol", ["❤️"])
        await react("106", on: "103", from: "ada", ["😀"])
        await react("107", on: "102", from: "carol", ["👍"])
        await react("108", on: "101", from: "dev", ["🎉"])
        await react("109", on: "101", from: "dev", [])
        await react("110", on: "103", from: "eve", ["👀", "🔥"])
        await applied("110", on: "103")

        XCTAssertEqual(seen.baseline(of: "general", ArrangementKey(server: record.id, account: "ada")), LogID("100"))
        XCTAssertEqual(unseen, unseen([("101", 1), ("103", 2)]), "Bob on 101; Carol and Eve on 103; not Ada's own, Dev's removed one or Bob's message")
        XCTAssertEqual(session.unseenReactionCount(in: "general"), 3)
        XCTAssertEqual(session.nextUnseenReaction(in: "general"), LogID("101"))
    }

    func testSeeingAMessageClearsItsOwnAndLeavesTheOnesFurtherUp() async throws {
        try await signIn()
        await post("101", from: "ada")
        await post("102", from: "ada")
        await react("103", on: "101", from: "bob", ["👍"])
        await react("104", on: "102", from: "bob", ["👍"])
        await applied("104", on: "102")

        session.markReactionsSeen([LogID("102")!])
        XCTAssertEqual(unseen, unseen([("101", 1)]), "the newer message seen first: the older one's reaction stays new")
        XCTAssertEqual(session.nextUnseenReaction(in: "general"), LogID("101"))
        session.markReactionsSeen([LogID("101")!])
        XCTAssertEqual(unseen, [])
        XCTAssertNil(session.nextUnseenReaction(in: "general"))

        await react("105", on: "101", from: "carol", ["🎉"])
        await applied("105", on: "101")
        XCTAssertEqual(unseen, unseen([("101", 1)]), "a reaction after the mark is new again")
    }

    func testOnlyTakingAReactionAwayLeavesItSeenWhileAChangeIsNew() async throws {
        try await signIn()
        await post("101", from: "ada")
        await react("102", on: "101", from: "bob", ["👍", "❤️"])
        await applied("102", on: "101")
        session.markReactionsSeen([LogID("101")!])

        await react("103", on: "101", from: "bob", ["❤"])
        await applied("103", on: "101")
        XCTAssertEqual(unseen, [], "👍 taken away, ❤ (without U+FE0F) already seen")
        await react("104", on: "101", from: "bob", ["😮"])
        await applied("104", on: "101")
        XCTAssertEqual(unseen, unseen([("101", 1)]), "changed to another emoji")
    }

    func testFirstSightIsTheRoomsHeadSoNothingOlderIsNewWhileWhatFollowsIs() async throws {
        try await signIn(latest: "200")
        await post("150", from: "ada")
        await react("160", on: "150", from: "bob", ["👍"])
        await react("201", on: "150", from: "carol", ["👍"])
        await applied("201", on: "150")
        XCTAssertEqual(unseen, unseen([("150", 1)]), "Bob's at 160 was there before the room was first seen")

        // A newer head listed later leaves the baseline where first sight put it.
        await socket.deliver(["method": "room_update", "params": ["updated": [["room_id": "general", "log_id": "250", "title": "General",
                                                                               "latest_log_id": "300", "history_log_id": "1"]]]])
        await eventually("listed again") { session.store.latestLogID(of: "general") == LogID("300") }
        XCTAssertEqual(seen.baseline(of: "general", ArrangementKey(server: record.id, account: "ada")), LogID("200"))
        XCTAssertEqual(unseen, unseen([("150", 1)]))
    }

    func testAHistoryPageCountsAsWhatHappenedWhileAway() async throws {
        try await signIn(latest: "100")
        let opening = Task { try await session.open("general") }
        await eventually("history asked") { await socket.sentLog.contains { $0.contains(#""method":"history""#) } }
        let sent = await socket.sentLog
        for frame in sent.dropFirst(2) {
            let request = try JSONValue(parsing: frame)
            guard let id = request["id"], request["method"]?.stringValue == "history" else { continue }
            await socket.deliver(["id": id, "result": [
                "messages": [
                    ["message_id": "90", "log_id": "90", "room_id": "general", "from": ["user_id": "ada"], "body": ["text": "old"]],
                    ["message_id": "120", "log_id": "120", "room_id": "general", "from": ["user_id": "ada"], "body": ["text": "while away"]],
                ],
                "reactions": [
                    ["log_id": "95", "message_id": "90", "room_id": "general", "reactions": [["from": ["user_id": "bob"], "emojis": ["👍"]]]],
                    ["log_id": "130", "message_id": "90", "room_id": "general", "reactions": [["from": ["user_id": "bob"], "emojis": ["👍", "🎉"]]]],
                    ["log_id": "131", "message_id": "120", "room_id": "general",
                     "reactions": [["from": ["user_id": "carol"], "emojis": ["❤️"]], ["from": ["user_id": "dev"], "emojis": ["❤️"]]]],
                ],
                "more": false, "first_log_id": "90", "last_log_id": "131", "latest_log_id": "131", "history_log_id": "1",
            ]])
        }
        try await opening.value
        XCTAssertEqual(unseen, unseen([("90", 1), ("120", 2)]),
                       "after the baseline of 100: Bob's change on the old message, and a compacted record of two")
    }

    func testARenameKeepsWhatWasSeenAndYourOldMessagesStayYours() async throws {
        try await signIn()
        await post("101", from: "ada")
        await post("102", from: "ada")
        await react("103", on: "101", from: "bob", ["👍"])
        await react("104", on: "102", from: "bob", ["👍"])
        await applied("104", on: "102")
        session.markReactionsSeen([LogID("101")!])

        await socket.deliver(["method": "user", "params": ["you": ["user_id": "ada2", "name": "Ada"]]])
        await eventually("renamed") { session.you?.userID == "ada2" }
        XCTAssertNil(seen.baseline(of: "general", ArrangementKey(server: record.id, account: "ada")))
        XCTAssertEqual(seen.baseline(of: "general", ArrangementKey(server: record.id, account: "ada2")), LogID("100"))
        XCTAssertEqual(seen.mark(on: LogID("101")!, ArrangementKey(server: record.id, account: "ada2")), LogID("103"))
        XCTAssertEqual(unseen, unseen([("102", 1)]))
    }

    func testWhatWasSeenIsKeptPerAccountAcrossALaunchAndCapped() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = UUID(), ada = ArrangementKey(server: server, account: "ada"), bob = ArrangementKey(server: server, account: "bob")
        let other = ArrangementKey(server: UUID(), account: "ada")
        let kept = SeenReactions(directory: directory)
        kept.firstSight(["general": LogID("100")!, "ops": LogID("40")!], ada)
        kept.firstSight(["general": LogID("500")!], ada)
        kept.firstSight(["general": LogID("7")!], other)
        kept.see([LogID("101")!: LogID("120")!], ada)
        kept.see([LogID("101")!: LogID("110")!], ada)

        let relaunched = SeenReactions(directory: directory)
        XCTAssertEqual(relaunched.baseline(of: "general", ada), LogID("100"), "first sight never moves")
        XCTAssertEqual(relaunched.baseline(of: "ops", ada), LogID("40"))
        XCTAssertNil(relaunched.baseline(of: "general", bob), "another account on the same server starts its own")
        XCTAssertEqual(relaunched.mark(on: LogID("101")!, ada), LogID("120"), "a mark never goes back")

        relaunched.rename(server: server, from: "ada", to: "ada2")
        let renamed = SeenReactions(directory: directory)
        XCTAssertEqual(renamed.baseline(of: "general", ArrangementKey(server: server, account: "ada2")), LogID("100"))
        XCTAssertEqual(renamed.mark(on: LogID("101")!, ArrangementKey(server: server, account: "ada2")), LogID("120"))
        XCTAssertNil(renamed.baseline(of: "general", ada))

        renamed.removeAll(server: server)
        let removed = SeenReactions(directory: directory)
        XCTAssertNil(removed.baseline(of: "general", ArrangementKey(server: server, account: "ada2")))
        XCTAssertEqual(removed.baseline(of: "general", other), LogID("7"), "another server's stays")

        let capped = SeenReactions()
        capped.see(Dictionary(uniqueKeysWithValues: (1 ... 2001).map { (LogID(String($0))!, LogID("9999")!) }), ada)
        XCTAssertNil(capped.mark(on: LogID("1")!, ada), "past 2000, the oldest message's mark goes")
        XCTAssertEqual(capped.mark(on: LogID("2")!, ada), LogID("9999"))
        XCTAssertEqual(capped.mark(on: LogID("2001")!, ada), LogID("9999"))
    }

    func testRemovingTheServerForgetsWhatWasSeenThere() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "apron-seen-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = Mutex(0)
        let transports = transports
        let environment = ServerSession.Environment(makeTransport: { _ in transports.next() },
                                                    makeRequestID: { counter.withLock { $0 += 1; return "c\($0)" } })
        let store = SessionStore(serverStore: ServerStore(directory: directory), tokens: InMemoryTokenStore(), environment: environment)
        let one = store.add(ServerRecord(url: URL(string: "wss://one.example/ws")!))
        await eventually("connected") { one.status == .signedOut }
        let socket = transports.made.withLock { $0[0] }
        let signIn = Task { try await one.signIn(.token("tok")) }
        await eventually("auth sent") { await socket.sentLog.count == 2 }
        await socket.deliver(["id": "c1", "result": ["you": ["user_id": "ada"]]])
        await socket.deliver(["id": "c2", "result": ["joined": [["room_id": "general", "log_id": "10", "latest_log_id": "100", "history_log_id": "1"]]]])
        _ = try await signIn.value
        let key = ArrangementKey(server: one.record.id, account: "ada")
        XCTAssertEqual(SeenReactions(directory: directory).baseline(of: "general", key), LogID("100"))

        await store.remove(one.record.id)
        XCTAssertNil(SeenReactions(directory: directory).baseline(of: "general", key))
    }
}
