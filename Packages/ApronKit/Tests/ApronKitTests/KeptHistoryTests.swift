import Foundation
import Synchronization
import XCTest
@testable import ApronKit

final class ArchiveTests: XCTestCase {
    private func message(_ id: String, _ text: String, room: String = "general", replyTo: String? = nil) -> JSONValue {
        var fields: [String: JSONValue] = ["message_id": .string(id), "log_id": .string(id), "room_id": .string(room),
                                           "from": ["user_id": "bob", "name": "Bob"], "body": ["text": .string(text)]]
        if let replyTo { fields["reply_to"] = ["message_id": .string(replyTo)] }
        return .object(fields)
    }

    func testWritesTheHeaderTheListingThenOneRecordPerLineInLogOrder() throws {
        var store = ReplayStore()
        store.apply(Records(roomListResult: ["joined": [["room_id": "general", "log_id": "1", "title": "General", "latest_log_id": "30",
                                                         "members": [["user_id": "ada"], ["user_id": "bob"]]]]]))
        store.apply(Records(historyResult: [
            "messages": [message("10", "old", room: "elsewhere"), message("20", "hi"), message("30", "re", replyTo: "10")],
            "reactions": [["log_id": "25", "message_id": "20", "room_id": "general", "reactions": [["from": ["user_id": "ada"], "emojis": ["👍"]]]]],
            "memberships": [["log_id": "22", "room_id": "general", "members": [["user": ["user_id": "cy"], "joined": true]]]],
        ]))
        let source = ArchiveSource(server: "wss://chat.example/", you: UserObject(["user_id": "ada", "name": "Ada", "status": "online"]),
                                   media: ["https://chat.example"], store: store,
                                   users: [UserObject(["user_id": "ada", "name": "Ada", "seen": "5"])!], joined: ["general"],
                                   rooms: [("general", .from(LogID("20")!))])
        let text = Archive.text(of: source, exportedAt: Date(timeIntervalSince1970: 1_793_102_400))
        XCTAssertEqual(text.split(separator: "\n").map(String.init), [
            #"{"apron_archive":1,"exported_at":"2026-10-27T12:00:00.000Z","media":["https://chat.example"],"server":"wss://chat.example/","you":{"name":"Ada","user_id":"ada"}}"#,
            #"{"joined":[{"history_log_id":"20","latest_log_id":"30","log_id":"1","members":[{"user_id":"ada"},{"user_id":"bob"}],"room_id":"general","title":"General"}],"not_joined":[],"users":[{"name":"Ada","user_id":"ada"}]}"#,
            #"{"messages":[{"body":{"text":"old"},"from":{"name":"Bob","user_id":"bob"},"log_id":"10","message_id":"10","room_id":"elsewhere"}]}"#,
            #"{"messages":[{"body":{"text":"hi"},"from":{"name":"Bob","user_id":"bob"},"log_id":"20","message_id":"20","room_id":"general"}]}"#,
            #"{"memberships":[{"log_id":"22","members":[{"joined":true,"user":{"user_id":"cy"}}],"room_id":"general"}]}"#,
            #"{"reactions":[{"log_id":"25","message_id":"20","reactions":[{"emojis":["👍"],"from":{"user_id":"ada"}}],"room_id":"general"}]}"#,
            #"{"messages":[{"body":{"text":"re"},"from":{"name":"Bob","user_id":"bob"},"log_id":"30","message_id":"30","reply_to":{"message_id":"10"},"room_id":"general"}]}"#,
        ])
        XCTAssertTrue(text.hasSuffix("}\n"))

        let read = try Archive(text: text)
        XCTAssertEqual(read.server, "wss://chat.example/")
        XCTAssertEqual(read.exportedAt, "2026-10-27T12:00:00.000Z")
        XCTAssertEqual(read.you?.json, ["user_id": "ada", "name": "Ada"])
        XCTAssertEqual(read.rooms.map(\.record.roomID), ["general"])
        XCTAssertEqual(read.rooms.first?.stretch, .from(LogID("20")!))
        XCTAssertEqual(read.rooms.first?.members, ["ada", "bob"])
        XCTAssertEqual(read.records.messages.map(\.messageID.text), ["10", "20", "30"])
        XCTAssertEqual(read.records.reactions.map(\.emojis), [["👍"]])
        XCTAssertEqual(read.records.memberships.map(\.user.userID), ["cy"])
        XCTAssertEqual(read.skipped, 0)
    }

    func testReadsARCHIVEmdsExampleAndSkipsWhatIsNotValid() throws {
        let text = [
            #"{"apron_archive":1,"server":"wss://chat.example/","exported_at":"2026-10-27T12:00:00.000Z","you":{"user_id":"ada","name":"Ada"},"media":["https://chat.example"]}"#,
            #"{"joined":[{"room_id":"general","log_id":"1724800000000","title":"General","latest_log_id":"1724803500000","history_log_id":"1724803200042","members":[{"user_id":"ada"},{"user_id":"bob"}]}],"not_joined":[],"users":[{"user_id":"ada","name":"Ada"},{"user_id":"bob","name":"Bob"}]}"#,
            "",
            #"{"messages":[{"message_id":"1724803200042","log_id":"1724803200042","room_id":"general","from":{"user_id":"bob","name":"Bob"},"body":{"text":"Hi!"}}]}"#,
            #"{"reactions":[{"log_id":"1724803312011","message_id":"1724803200042","room_id":"general","reactions":[{"from":{"user_id":"ada","name":"Ada"},"emojis":["👍"]}]}]}"#,
            "not json",
            #"{"messages":[{"message_id":"x"}],"more":true}"#,
            #"{"unknown":[]}"#,
        ].joined(separator: "\r\n")
        let archive = try Archive(text: text)
        XCTAssertEqual(archive.users.map(\.userID), ["ada", "bob"])
        XCTAssertEqual(archive.rooms.first?.latest, LogID("1724803500000"))
        XCTAssertEqual(archive.rooms.first?.stretch, .from(LogID("1724803200042")!))
        XCTAssertEqual(archive.records.messages.map(\.messageID.text), ["1724803200042"])
        XCTAssertEqual(archive.records.reactions.count, 1)
        XCTAssertEqual(archive.skipped, 3, "the line that is not JSON, the invalid message and the line with no known key")
    }

    func testRefusesAFileThatIsNoArchiveOrFromANewerVersion() {
        XCTAssertThrowsError(try Archive(text: #"{"joined":[]}"#)) { XCTAssertEqual($0 as? ArchiveError, .notAnArchive) }
        XCTAssertThrowsError(try Archive(text: "")) { XCTAssertEqual($0 as? ArchiveError, .notAnArchive) }
        XCTAssertThrowsError(try Archive(text: #"{"apron_archive":2}"#)) { XCTAssertEqual($0 as? ArchiveError, .newerVersion) }
        XCTAssertEqual(ArchiveError.notAnArchive.description, "This file isn’t an Apron export.")
    }

    func testAListingSaysWhereItsStretchStarts() throws {
        let archive = try Archive(text: [
            #"{"apron_archive":1}"#,
            #"{"joined":[{"room_id":"a"},{"room_id":"b","history_log_id":null},{"room_id":"c","history_log_id":"7"}]}"#,
        ].joined(separator: "\n"))
        XCTAssertEqual(archive.rooms.map(\.stretch), [.fromOldest, .none, .from(LogID("7")!)])
    }
}

final class LogEntryTests: XCTestCase {
    private func entry(_ id: String, user: String = "bob") -> LogEntry {
        .membership(Membership(logID: LogID(id)!, roomID: "general", user: UserObject(["user_id": .string(user)])!, joined: true))
    }

    func testPagesTheNewestOrTheOldestAfterABoundAndKeepsOneLogIDWhole() {
        let log = [entry("1"), entry("2"), entry("3", user: "ada"), entry("3", user: "bob"), entry("4"), entry("5")]
        let newest = LogEntry.slice(log, limit: 2)
        XCTAssertEqual(newest.page.map(\.logID.text), ["4", "5"])
        XCTAssertTrue(newest.more)
        let before = LogEntry.slice(log, before: LogID("3")!, limit: 1)
        XCTAssertEqual(before.page.map(\.logID.text), ["3", "3"], "a record's entries go together, past the limit")
        XCTAssertTrue(before.more)
        let after = LogEntry.slice(log, after: LogID("4")!, limit: 5)
        XCTAssertEqual(after.page.map(\.logID.text), ["4", "5"])
        XCTAssertFalse(after.more)
        XCTAssertTrue(LogEntry.slice(log, after: LogID("9")!, limit: 5).page.isEmpty)
    }
}

final class HistoryRetentionTests: XCTestCase {
    func testTheChoicesAreApronWebsInItsOrderAndWords() {
        XCTAssertEqual(HistoryRetention.allCases.map(\.label), ["Don’t keep", "A day", "A week", "30 days", "A year", "Forever"])
        XCTAssertEqual(HistoryRetention.allCases.map(\.rawValue), ["off", "1", "7", "30", "365", "all"])
        XCTAssertEqual(HistoryRetention.default, .month)
        XCTAssertEqual(HistoryRetention.month.title, "30 Days")
        XCTAssertEqual(HistoryRetention.off.title, "Don’t Keep")
        XCTAssertEqual(HistoryRetention.off.rule.perRoom, 150)
        XCTAssertEqual(HistoryRetention.off.rule.age, 86_400)
        XCTAssertNil(HistoryRetention.forever.rule.age)
    }

    func testSizesAreWordedAsApronWebWordsThem() {
        XCTAssertEqual(HistorySettings.words(bytes: 1000), "under 1 MB")
        XCTAssertEqual(HistorySettings.words(bytes: 12 * 1024 * 1024 + 400_000), "12 MB")
        XCTAssertEqual(HistorySettings.words(bytes: 3 * 1024 * 1024 * 1024 / 2), "1.5 GB")
    }

    @MainActor
    func testTheChoiceIsKeptBesideTheServers() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(HistorySettings(directory: directory).retention, .month)
        HistorySettings(directory: directory).update(.year)
        XCTAssertEqual(HistorySettings(directory: directory).retention, .year)
    }

    func testTheFolderIsLeftOutOfBackups() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = FileHistoryFiles(directory: directory)
        let server = UUID()
        try files.write(Data("x".utf8), for: server)
        XCTAssertEqual(files.read(server), Data("x".utf8))
        XCTAssertEqual(try files.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        files.remove(server)
        XCTAssertNil(files.read(server))
    }
}

final class KeptRestoreTests: XCTestCase {
    /// 2026-10-31 12:00 UTC.
    let now = Date(timeIntervalSince1970: 1_793_448_000)

    private func ms(daysAgo: Double) -> String { String(Int64((now.timeIntervalSince1970 - daysAgo * 86_400) * 1000)) }

    private func kept(_ rooms: [String: JSONValue], messages: [(room: String, id: String)]) -> Data {
        let lines: [JSONValue] = [
            ["apron_archive": 1, "you": ["user_id": "ada"], "ladle_kept": ["rooms": .object(rooms)]],
            ["joined": .array(rooms.keys.sorted().map { ["room_id": .string($0)] })],
        ] + messages.map { message in
            ["messages": [["message_id": .string(message.id), "log_id": .string(message.id), "room_id": .string(message.room), "from": ["user_id": "bob"]]]]
        }
        return Data(lines.map { $0.serialized() }.joined(separator: "\n").utf8)
    }

    func testAStaleRoomStartsOverAndAKeptLogStopsAtTheCutoff() throws {
        let data = kept([
            "stale": ["checkpoint": .string(ms(daysAgo: 40)), "older": true, "start": .string(ms(daysAgo: 50))],
            "fresh": ["checkpoint": .string(ms(daysAgo: 1)), "older": false, "start": .string(ms(daysAgo: 60)),
                      "caught_up_at": .number(String(Int64(now.timeIntervalSince1970 * 1000)))],
        ], messages: [("stale", ms(daysAgo: 41)), ("fresh", ms(daysAgo: 45)), ("fresh", ms(daysAgo: 2))])
        let restore = try XCTUnwrap(KeptRestore(data: data, account: "ada", retention: .month, now: now))
        XCTAssertEqual(Set(restore.rooms.keys), ["fresh"], "not caught up within 30 days: paging forward would fetch everything since")
        XCTAssertEqual(restore.joined, ["fresh", "stale"], "the room itself still shows")
        XCTAssertEqual(restore.kept.messages(in: "stale"), [])
        XCTAssertEqual(restore.kept.messages(in: "fresh").map(\.messageID.text), [ms(daysAgo: 2)])
        let fresh = try XCTUnwrap(restore.rooms["fresh"])
        XCTAssertEqual(fresh.sync.start, LogID(ms(daysAgo: 30)))
        XCTAssertTrue(fresh.sync.older, "older pages below the cutoff come from the server")
        XCTAssertEqual(fresh.history.checkpoint, LogID(ms(daysAgo: 1)))
        XCTAssertTrue(fresh.history.more)

        let forever = try XCTUnwrap(KeptRestore(data: data, account: "ada", retention: .forever, now: now))
        XCTAssertEqual(Set(forever.rooms.keys), ["fresh", "stale"])
        XCTAssertEqual(forever.kept.messages(in: "fresh").count, 2)
        XCTAssertFalse(forever.rooms["fresh"]!.history.more, "kept down to the start of the room")
    }

    func testAnotherAccountsHistoryIsNotRestored() {
        XCTAssertNil(KeptRestore(data: kept([:], messages: []), account: "bob", retention: .forever, now: now))
        XCTAssertNil(KeptRestore(data: Data("nope".utf8), account: "ada", retention: .forever, now: now))
    }

    func testShowsTheNewestFiftyEntriesAndKeepsTheRestToPage() throws {
        let ids = (1001 ... 1060).map(String.init)
        let data = kept(["general": ["checkpoint": "1060", "older": true, "start": "1001"]], messages: ids.map { ("general", $0) })
        let restore = try XCTUnwrap(KeptRestore(data: data, account: "ada", retention: .forever, now: now))
        let room = try XCTUnwrap(restore.rooms["general"])
        XCTAssertEqual(room.window.map(\.logID.text), Array(ids.suffix(50)))
        XCTAssertEqual(room.history.olderBefore, LogID("1010"))
        XCTAssertEqual(restore.kept.messages(in: "general").count, 60)
    }
}

@MainActor
final class KeptHistorySessionTests: XCTestCase {
    static let greeting: JSONValue = ["method": "server", "params": ["apron": 9, "auth": ["token", "guest"], "capabilities": ["history", "rooms"]]]
    let record = ServerRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000000009")!, url: URL(string: "wss://chat.example/ws")!)
    let tokens = InMemoryTokenStore()
    let files = InMemoryHistoryFiles()
    let transports = Transports()
    var sessions: [ServerSession] = []

    override func tearDown() async throws {
        for session in sessions { await session.stop() }
    }

    private func session(_ record: ServerRecord, settings: HistorySettings = HistorySettings()) -> ServerSession {
        let counter = Mutex(0)
        let transports = transports
        let environment = ServerSession.Environment(
            makeTransport: { _ in transports.next() }, sleep: { try await Task.sleep(for: $0) }, jitter: { 1 },
            makeRequestID: { counter.withLock { $0 += 1; return "c\($0)" } }, makeState: { "s" }, agent: "ladle-ios/test", pageSize: 3)
        let session = ServerSession(record: record, tokens: tokens, keeping: HistoryKeeping(files: files, settings: settings), environment: environment)
        sessions.append(session)
        return session
    }

    private func frame(_ transport: FakeTransport, _ index: Int) async -> String {
        await eventually("frame \(index)") { await transport.sentLog.count > index }
        return await transport.sentLog[index]
    }

    private func message(_ id: Int) -> JSONValue {
        ["message_id": .string(String(id)), "log_id": .string(String(id)), "room_id": "general", "from": ["user_id": "bob"], "body": ["text": .string("#\(id)")]]
    }

    /// Signs in as Ada with a token, opens general with 1001–1060 kept, and writes what is kept.
    private func keptSession() async throws -> ServerSession {
        let socket = FakeTransport()
        transports.queued.withLock { $0 = [socket] }
        await socket.deliver(Self.greeting)
        let first = session(record)
        first.start()
        await eventually("signed out") { first.status == .signedOut }
        let signIn = Task { try await first.signIn(.guest(name: nil)) }
        _ = await frame(socket, 1)
        await socket.deliver(["id": "c1", "result": ["you": ["user_id": "ada", "name": "Ada"], "token": "t1"]])
        await socket.deliver(["id": "c2", "result": ["joined": [["room_id": "general", "log_id": "900", "title": "General", "latest_log_id": "1060"]]]])
        _ = try await signIn.value
        let open = Task { try await first.open("general") }
        _ = await frame(socket, 2)
        await socket.deliver(["id": "c3", "result": ["messages": .array((1001 ... 1060).map(message)), "first_log_id": "1001", "last_log_id": "1060",
                                                      "more": true, "latest_log_id": "1060", "history_log_id": "950"]])
        _ = await frame(socket, 3)
        await socket.deliver(["id": "c4", "result": ["not_joined": []]])
        try await open.value
        await first.flushKept()
        return first
    }

    func testARelaunchShowsWhatWasKeptAtOnceThenCatchesUpFromItsCheckpoint() async throws {
        let first = try await keptSession()
        let text = try XCTUnwrap(files.read(record.id).flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(text.hasPrefix(#"{"apron_archive":1,"#))
        await first.stop()

        let socket = FakeTransport()
        transports.queued.withLock { $0 = [socket] }
        let second = session(first.record)
        second.start()
        await eventually("restored") { second.timeline("general").count == 50 }
        XCTAssertEqual(second.status, .connecting, "shown before the server greets")
        XCTAssertEqual(second.you?.userID, "ada")
        XCTAssertEqual(second.joinedRoomIDs, ["general"])

        await socket.deliver(Self.greeting)
        let auth = await frame(socket, 0)
        XCTAssertEqual(auth, #"{"id":"c1","method":"auth","params":{"agent":"ladle-ios/test","scheme":"token","token":"t1"}}"#)
        await socket.deliver(["id": "c1", "result": ["you": ["user_id": "ada", "name": "Ada"]]])
        await socket.deliver(["id": "c2", "result": ["joined": [["room_id": "general", "log_id": "900", "latest_log_id": "1061"]]]])
        let catchUp = await frame(socket, 2)
        XCTAssertEqual(catchUp, #"{"id":"c3","method":"history","params":{"after":"1061","limit":200,"room_id":"general"}}"#)
        await socket.deliver(["id": "c3", "result": ["messages": [message(1061)], "first_log_id": "1061", "last_log_id": "1061", "more": false,
                                                      "latest_log_id": "1061", "history_log_id": "950"]])
        _ = await frame(socket, 3)
        await socket.deliver(["id": "c4", "result": ["not_joined": []]])
        await eventually("caught up") { second.timeline("general").last?.messageID == LogID("1061") }

        try await second.loadOlder("general")
        XCTAssertEqual(second.timeline("general").first?.messageID, LogID("1008"), "the next page came from the device")
        let sent = await socket.sentLog.count
        XCTAssertEqual(sent, 4, "nothing asked of the server")
        while second.timeline("general").first?.messageID != LogID("1001") { try await second.loadOlder("general") }
        let still = await socket.sentLog.count
        XCTAssertEqual(still, 4)

        let older = Task { try await second.loadOlder("general") }
        let fromServer = await frame(socket, 4)
        XCTAssertEqual(fromServer, #"{"id":"c5","method":"history","params":{"before":"1000","limit":3,"room_id":"general"}}"#,
                       "the device's kept log ran out: the server's older pages follow")
        await socket.deliver(["id": "c5", "result": ["messages": [message(998), message(999), message(1000)], "first_log_id": "998",
                                                      "last_log_id": "1000", "more": false, "latest_log_id": "1061", "history_log_id": "950"]])
        try await older.value
        XCTAssertEqual(second.timeline("general").first?.messageID, LogID("998"))
    }

    func testSearchFindsWhatTheDeviceKeepsBeyondWhatTheRoomShows() async throws {
        let first = try await keptSession()
        await first.stop()
        transports.queued.withLock { $0 = [FakeTransport()] }
        let second = session(first.record)
        second.start()
        await eventually("restored") { second.timeline("general").count == 50 }
        XCTAssertFalse(second.timeline("general").contains { $0.messageID == LogID("1003") })

        let found = await second.search("#1003")
        XCTAssertEqual(found.messages.map(\.messageID.text), ["1003"], "kept, though the room shows only its newest 50")
        let hit = second.hit(try XCTUnwrap(found.messages.first), in: found)
        XCTAssertEqual(hit.place, "General")
        XCTAssertEqual(hit.parts, [SnippetPart("#1003", match: true)])

        let several = await second.search("#100")
        XCTAssertEqual(several.messages.map(\.messageID.text), ["1009", "1008", "1007", "1006", "1005", "1004", "1003", "1002", "1001"],
                       "newest first; #1000 and #1010 on are other words")
        let inRoom = await second.search(ServerSession.searchStart(in: "general") + "#1003")
        XCTAssertEqual(inRoom.messages.count, 1)
        let elsewhere = await second.search("room:#random #1003")
        XCTAssertEqual(elsewhere.messages, [])
        let byBob = await second.search("user:@bob #1003")
        XCTAssertEqual(byBob.messages.count, 1)
        let empty = await second.search("   ")
        XCTAssertEqual(empty.messages, [])
        XCTAssertEqual(second.rooms(named: "gen").map(\.id), ["general"])
        XCTAssertEqual(second.rooms(named: "GÉNÉ").map(\.id), ["general"], "any case, with or without accents")
        XCTAssertEqual(second.rooms(named: "zzz").map(\.id), [])
    }

    func testTheNoteSaysWhatIsSearched() async throws {
        let first = try await keptSession()
        XCTAssertEqual(first.searchNote, "Messages kept on this device from the last 30 days, and those loaded now.")
        XCTAssertEqual(first.searchKept, "30 Days")
        first.keeping?.settings.update(.forever)
        XCTAssertEqual(first.searchNote, "Messages kept on this device, and those loaded now.")
        XCTAssertEqual(ServerSession.searchStart(in: nil), "")
    }

    func testSigningOutDeletesWhatIsKept() async throws {
        let first = try await keptSession()
        XCTAssertNotNil(files.read(record.id))
        await first.signOut()
        XCTAssertNil(files.read(record.id))
    }

    func testDontKeepKeepsTheNewest150OfTheLastDay() async throws {
        let first = try await keptSession()
        let settings = try XCTUnwrap(first.keeping?.settings)
        XCTAssertNotNil(settings.keptBytes[record.id])
        XCTAssertEqual(settings.used, "under 1 MB")
        settings.update(.off)
        let source = try XCTUnwrap(first.keptSource(now: Date()))
        XCTAssertEqual(source.rooms.map(\.stretch), [.from(LogID("1001")!)], "positions that are not times have no age to cut at")
    }
}
