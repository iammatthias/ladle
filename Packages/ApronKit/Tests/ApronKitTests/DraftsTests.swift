import XCTest
@testable import ApronKit

@MainActor
final class DraftsTests: XCTestCase {
    private let server = UUID(uuidString: "6F1C3E1A-0000-4000-8000-000000000001")!
    private let other = UUID(uuidString: "6F1C3E1A-0000-4000-8000-000000000002")!
    private var folders: [URL] = []

    override func tearDown() {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
    }

    private func folder() throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "DraftsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        folders.append(url)
        return url
    }

    /// A ready file staged as the preparer writes one: in a folder of its own under `staging`.
    private func staged(_ name: String, in staging: URL, folder: String) throws -> StagedFile {
        let directory = staging.appending(path: folder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        try Data("png".utf8).write(to: url)
        return StagedFile(name: name, phase: .ready(Attachment(fileURL: url, title: name, contentType: "image/png", byteCount: 3,
                                                                 pixelWidth: 40, pixelHeight: 30)))
    }

    func testADraftComesBackAfterARelaunchWithItsReplyMentionsAndReadyFiles() throws {
        let directory = try folder()
        let staging = directory.appending(path: "Staged", directoryHint: .isDirectory)
        let general = DraftKey(server: server, roomID: "general")
        let first = Drafts(store: FileDraftStore(directory: directory), staging: staging)
        first[general] = ComposerDraft(field: DraftField(mode: .reply(LogID("1724803200043")!), text: "Thanks @Ada", mentions: ["ada": "Ada"]),
                                       files: [try staged("Shot.png", in: staging, folder: "A1"), StagedFile(name: "Preparing", phase: .preparing)])

        let relaunched = Drafts(store: FileDraftStore(directory: directory), staging: staging)
        let draft = relaunched[general]
        XCTAssertEqual(draft.field.text, "Thanks @Ada")
        XCTAssertEqual(draft.field.mentions, ["ada": "Ada"])
        XCTAssertEqual(draft.field.replyTo, LogID("1724803200043"))
        XCTAssertEqual(draft.files.map(\.name), ["Shot.png"], "a file still being fitted is not kept")
        XCTAssertEqual(draft.files.first?.attachment?.fileURL.path, staging.appending(path: "A1/Shot.png").path)
        XCTAssertEqual(draft.files.first?.attachment?.pixelWidth, 40)
        let saved = try String(contentsOf: directory.appending(path: "drafts.json"), encoding: .utf8)
        XCTAssertTrue(saved.contains("\"path\" : \"A1\\/Shot.png\""), "paths are relative to the staging folder: \(saved)")
    }

    func testFilesFollowTheStagingFolderWhenTheContainerMoves() throws {
        let directory = try folder()
        let before = directory.appending(path: "Before/Staged", directoryHint: .isDirectory)
        let after = directory.appending(path: "After/Staged", directoryHint: .isDirectory)
        let key = DraftKey(server: server, roomID: "general")
        Drafts(store: FileDraftStore(directory: directory), staging: before)[key] = ComposerDraft(files: [try staged("a.png", in: before, folder: "F")])
        try FileManager.default.createDirectory(at: after.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: before, to: after)

        let moved = Drafts(store: FileDraftStore(directory: directory), staging: after)[key]
        XCTAssertEqual(moved.files.compactMap(\.attachment?.fileURL.path), [after.appending(path: "F/a.png").path])
        try FileManager.default.removeItem(at: after.appending(path: "F"))
        XCTAssertTrue(Drafts(store: FileDraftStore(directory: directory), staging: after)[key].isEmpty, "a file gone from staging is left out")
    }

    func testEachRoomAndThreadKeepsItsOwnDraftAndAnEmptyOneIsForgotten() throws {
        let directory = try folder()
        let drafts = Drafts(store: FileDraftStore(directory: directory), staging: directory.appending(path: "Staged"))
        let room = DraftKey(server: server, roomID: "general"), thread = DraftKey(server: server, roomID: "release-notes")
        drafts[room].field.text = "in the room"
        drafts[thread].field.text = "in the thread"
        drafts[DraftKey(server: other, roomID: "general")].field.text = "on the other server"
        XCTAssertEqual(drafts[room].field.text, "in the room")
        XCTAssertEqual(drafts[thread].field.text, "in the thread")
        drafts[thread] = ComposerDraft()

        let relaunched = Drafts(store: FileDraftStore(directory: directory), staging: directory.appending(path: "Staged"))
        XCTAssertEqual(relaunched.byKey.mapValues(\.field.text),
                       [room: "in the room", DraftKey(server: other, roomID: "general"): "on the other server"])
    }

    func testAnEditIsNeverKept() async throws {
        let directory = try folder()
        let fixtures = await PreviewFixtures.makeStore()
        let home = try XCTUnwrap(fixtures.session(for: PreviewFixtures.homeID))
        let key = DraftKey(server: server, roomID: "general")
        Drafts(store: FileDraftStore(directory: directory), staging: directory)[key] =
            ComposerDraft(field: DraftField(editing: home.timeline("general")[0], in: home))
        XCTAssertEqual(Drafts(store: FileDraftStore(directory: directory), staging: directory).byKey, [:])
    }

    func testAnOlderOrDamagedFileLoadsWhatItCan() throws {
        let directory = try folder()
        let json = """
        {"\(server.uuidString)": {"general": {"text": "hi", "reply_to": 5, "files": [{"bogus": 1}]},
                                  "design": {"mentions": {"ada": "Ada"}, "text": "@Ada"}},
         "not-a-uuid": {"general": {"text": "lost"}}}
        """
        try Data(json.utf8).write(to: directory.appending(path: "drafts.json"))
        let drafts = Drafts(store: FileDraftStore(directory: directory), staging: directory)
        XCTAssertEqual(drafts.byKey, [
            DraftKey(server: server, roomID: "general"): ComposerDraft(field: DraftField(text: "hi")),
            DraftKey(server: server, roomID: "design"): ComposerDraft(field: DraftField(text: "@Ada", mentions: ["ada": "Ada"])),
        ])
    }

    func testPruningKeepsOnlyTheFilesADraftHolds() throws {
        let directory = try folder()
        let staging = directory.appending(path: "Staged", directoryHint: .isDirectory)
        let drafts = Drafts(store: FileDraftStore(directory: directory), staging: staging)
        drafts[DraftKey(server: server, roomID: "general")] = ComposerDraft(files: [try staged("keep.png", in: staging, folder: "Kept")])
        _ = try staged("sent.png", in: staging, folder: "Sent")

        Drafts(store: FileDraftStore(directory: directory), staging: staging).pruneStaging()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path), ["Kept"])
        XCTAssertEqual(try staging.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testRemovingAServerForgetsItsDraftsAndTheirFiles() async throws {
        let directory = try folder()
        let store = SessionStore(serverStore: ServerStore(directory: directory), tokens: InMemoryTokenStore())
        let record = ServerRecord(url: URL(string: "wss://chat.example/ws")!)
        let session = store.add(record)
        await session.stop()
        let file = try staged("a.png", in: store.drafts.staging, folder: "F")
        store.drafts[DraftKey(server: record.id, roomID: "general")] = ComposerDraft(field: DraftField(text: "bye"), files: [file])
        store.drafts[DraftKey(server: other, roomID: "general")].field.text = "stays"

        await store.remove(record.id)
        XCTAssertEqual(store.drafts.byKey.mapValues(\.field.text), [DraftKey(server: other, roomID: "general"): "stays"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.drafts.staging.appending(path: "F").path))
        XCTAssertEqual(Drafts(store: FileDraftStore(directory: directory), staging: store.drafts.staging).byKey.count, 1)
    }
}
