import Foundation
import XCTest
@testable import ApronKit

/// Exports and reading them back, as apron-web's `archive.test.ts`.
@MainActor
final class ArchiveExportTests: XCTestCase {
    private var readers: [ServerSession] = []

    override func tearDown() async throws {
        for reader in readers { await reader.stop() }
    }

    private func source() async throws -> ServerSession {
        let store = await PreviewFixtures.makeStore()
        let home = try XCTUnwrap(store.session(for: PreviewFixtures.homeID))
        await eventually("signed in") { home.status == .signedIn }
        try await home.open(PreviewFixtures.busyRoomID)
        try await home.open(PreviewFixtures.releaseThreadID)
        try await home.open(PreviewFixtures.directRoomID)
        return home
    }

    private func reader(_ archive: Archive, withImages: Bool = true) async throws -> ServerSession {
        let reader = ServerSession.reading(archive, withImages: withImages)
        readers.append(reader)
        reader.start()
        await eventually("greeted") { reader.status == .signedOut }
        _ = try await reader.signIn(.guest(name: nil))
        return reader
    }

    private func texts(_ session: ServerSession, _ roomID: String) -> [String] {
        session.timeline(roomID).map { "\($0.messageID.text) \(MessageText.plain($0.body))" }
    }

    func testReadsBackAsWhatTheSessionShowedReadOnly() async throws {
        let home = try await source()
        let export = home.exportArchive(includingPrivate: true, now: Date(timeIntervalSince1970: 1_793_102_400))
        XCTAssertEqual(export.name, "apron-home.example-2026-10-27.jsonl")
        let archive = try Archive(text: export.text)
        XCTAssertEqual(archive.server, "wss://home.example/ws")
        XCTAssertEqual(archive.exportedAt, "2026-10-27T12:00:00.000Z")
        XCTAssertEqual(archive.media, ["https://home.example"])
        XCTAssertEqual(archive.skipped, 0)

        let reader = try await reader(archive)
        XCTAssertEqual(reader.server?.auth, ["guest"])
        XCTAssertFalse(reader.mayWrite, "read-only")
        XCTAssertEqual(reader.you?.userID, home.you?.userID)
        XCTAssertEqual(reader.server?.ext?["archive"], ["server": "wss://home.example/ws", "exported_at": "2026-10-27T12:00:00.000Z"])
        XCTAssertEqual(reader.server?.ext?["media"], ["origins": ["https://home.example"]])
        XCTAssertTrue(reader.archiveNote?.hasPrefix("An export from home.example, saved ") == true)
        XCTAssertTrue(reader.archiveNote?.hasSuffix(". It’s read-only.") == true)

        for room in [PreviewFixtures.busyRoomID, PreviewFixtures.releaseThreadID] {
            try await reader.open(room)
            while reader.canLoadOlder(room) { try await reader.loadOlder(room) }
            XCTAssertGreaterThan(texts(home, room).count, 2, room)
            XCTAssertEqual(texts(reader, room), texts(home, room), room)
        }
        let reacted = try XCTUnwrap(home.timeline(PreviewFixtures.busyRoomID).first { home.store.reactions(on: $0.messageID) != nil })
        XCTAssertEqual(reader.store.reactions(on: reacted.messageID), home.store.reactions(on: reacted.messageID))
        XCTAssertEqual(reader.store.members(of: PreviewFixtures.busyRoomID)?.map(\.userID), home.store.members(of: PreviewFixtures.busyRoomID)?.map(\.userID))

        do {
            _ = try await reader.send("hello", in: PreviewFixtures.busyRoomID)
            XCTFail("an archive took a message")
        } catch let error as RPCError {
            XCTAssertEqual(error.message, "This is a read-only archive: nothing in it can change.")
        }
    }

    func testOpensWithoutImagesUnlessTheReaderAgrees() async throws {
        let archive = try Archive(text: try await source().exportArchive(includingPrivate: false).text)
        XCTAssertEqual(archive.mediaHosts, ["home.example"])
        let reader = try await reader(archive, withImages: false)
        XCTAssertNil(reader.server?.ext?["media"])
        XCTAssertFalse(reader.server?.has("ext:media") ?? true)
    }

    func testLeavesOutPrivateRoomsAndAnyoneKnownOnlyFromThemUnlessAsked() async throws {
        let home = try await source()
        let privates = home.store.roomIDs.filter { home.store.room($0)?.isPrivate == true && home.store.room($0)?.parentRoomID == nil }
        XCTAssertFalse(privates.isEmpty)
        let left = home.exportArchive(includingPrivate: false)
        XCTAssertEqual(left.privateLeftOut, privates.count)
        let without = try Archive(text: left.text)
        let listed = without.rooms.map(\.record.roomID)
        for id in privates { XCTAssertFalse(listed.contains(id), id) }
        XCTAssertTrue(listed.contains(PreviewFixtures.busyRoomID))
        XCTAssertFalse(without.records.messages.contains { privates.contains($0.roomID) })
        XCTAssertTrue(left.words.hasSuffix("; \(privates.count) private room\(privates.count == 1 ? "" : "s") left out."))

        let all = home.exportArchive(includingPrivate: true)
        XCTAssertEqual(all.privateLeftOut, 0)
        let with = try Archive(text: all.text)
        XCTAssertTrue(with.records.messages.contains { $0.roomID == PreviewFixtures.directRoomID })
        XCTAssertGreaterThanOrEqual(with.users.count, without.users.count)
    }

    func testKeepsStatusesOutAndListsWhereEachStretchStarts() async throws {
        let home = try await source()
        let archive = try Archive(text: home.exportArchive(includingPrivate: true).text)
        XCTAssertFalse(archive.users.contains { $0.json["status"] != nil || $0.json["seen"] != nil })
        let thread = try XCTUnwrap(archive.rooms.first { $0.record.roomID == PreviewFixtures.releaseThreadID })
        XCTAssertTrue(thread.joined)
        let start = home.histories[PreviewFixtures.releaseThreadID]?.olderBefore?.successor
        XCTAssertEqual(thread.stretch, start.map(ArchiveStretch.from) ?? .fromOldest)
        let listed = Set(archive.rooms.map(\.record.roomID))
        XCTAssertTrue(archive.records.messages.allSatisfy { listed.contains($0.roomID) })
    }

    func testPagesARoomOlderThanOnePageNewestFirst() async throws {
        let messages = (0 ..< 450).map { index -> String in
            let id = String(1_720_000_000_000 + index)
            return JSONValue.object(["messages": [["message_id": .string(id), "log_id": .string(id), "room_id": "general", "from": ["user_id": "ada"],
                                                   "body": ["text": .string("#\(index)")]]]]).serialized()
        }
        // Hand-written, as another tool might: no `log_id` for the room, and no `history_log_id`.
        let archive = try Archive(text: ([#"{"apron_archive":1,"server":"wss://chat.example/","exported_at":"2026-10-27T12:00:00.000Z"}"#,
                                          #"{"joined":[{"room_id":"general","title":"General"}]}"#] + messages).joined(separator: "\n"))
        let reader = try await reader(archive)
        try await reader.open("general")
        while reader.canLoadOlder("general") { try await reader.loadOlder("general") }
        let shown = reader.timeline("general")
        XCTAssertEqual(shown.count, 450)
        XCTAssertEqual(MessageText.plain(shown.first?.body), "#0")
    }

    func testServesAReplysTargetFromOutsideEveryStretchOnlyAsTheSnapshotItEmbeds() async throws {
        func message(_ id: Int, _ room: String, replyTo: Int? = nil) -> JSONValue {
            var fields: [String: JSONValue] = ["message_id": .string(String(id)), "log_id": .string(String(id)), "room_id": .string(room),
                                               "from": ["user_id": "ada"], "body": ["text": .string("#\(id)")]]
            if let replyTo { fields["reply_to"] = ["message_id": .string(String(replyTo))] }
            return .object(fields)
        }
        let server = ArchiveServer(archive: try Archive(text: [
            #"{"apron_archive":1}"#,
            #"{"joined":[{"room_id":"general","log_id":"1","latest_log_id":"30","history_log_id":"20"}]}"#,
            JSONValue.object(["messages": [message(10, "general"), message(5, "elsewhere")]]).serialized(),
            JSONValue.object(["messages": [message(20, "general", replyTo: 10), message(30, "general", replyTo: 5)]]).serialized(),
        ].joined(separator: "\n")), withImages: false)
        try await server.connect()
        _ = try await server.receive()
        try await server.send(#"{"id":"1","method":"history","params":{"room_id":"general"}}"#)
        let result = try JSONValue(parsing: try await server.receive())["result"]
        XCTAssertEqual(result?["history_log_id"], "20")
        XCTAssertEqual(result?["latest_log_id"], "30")
        XCTAssertEqual(result?["first_log_id"], "20")
        XCTAssertEqual(result?["last_log_id"], "30")
        XCTAssertEqual(result?["more"], false)
        XCTAssertEqual(result?["messages"]?.arrayValue?.map { [$0["message_id"], $0["reply_to"]?["body"]] }, [["20", ["text": "#10"]], ["30", ["text": "#5"]]])
        try await server.send(#"{"id":"2","method":"history","params":{"room_id":"elsewhere"}}"#)
        let refused = try JSONValue(parsing: try await server.receive())
        XCTAssertEqual(refused["error"]?["code"], -32602)
    }

    func testALinkIntoAnExportNamesItsAddressSoTheViewerKeepsIt() async throws {
        let reader = try await reader(try Archive(text: try await source().exportArchive(includingPrivate: false).text))
        let url = try XCTUnwrap(ApronLink(server: reader.record.url, room: PreviewFixtures.busyRoomID, message: LogID("1793091780000")).webURL)
        let link = try XCTUnwrap(ApronLink(url))
        XCTAssertEqual(link.server?.host(), "archive.invalid")
        XCTAssertEqual(link.server?.host(), ServerSession.archiveURL.host())
        XCTAssertEqual(link.room, PreviewFixtures.busyRoomID)
    }

    func testNamesTheFileAfterTheServersHostAndTheDay() {
        let day = Date(timeIntervalSince1970: 1_793_102_400)
        XCTAssertEqual(Archive.fileName(server: URL(string: "wss://Chat.Example/ws")!, date: day), "apron-chat.example-2026-10-27.jsonl")
        XCTAssertEqual(Archive.fileName(server: URL(string: "ws://localhost:8080/")!, date: day), "apron-localhost-8080-2026-10-27.jsonl")
    }
}
