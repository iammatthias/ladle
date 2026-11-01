import XCTest
@testable import ApronKit

@MainActor
final class MessageEditTests: XCTestCase {
    private func message(_ embeds: [JSONValue], reply: String? = "150") -> MessageSnapshot {
        MessageSnapshot(messageID: LogID("200")!, logID: LogID("200")!, roomID: "general", from: UserObject(["user_id": "sam"])!,
                        body: ["text": "Two of mine", "format": "plain", "mentions": ["ada"], "embeds": .array(embeds)],
                        replyTo: reply.flatMap(LogID.init), ext: ["k": 1])
    }

    private let photo: JSONValue = ["embed_id": "e1", "kind": "upload", "title": "IMG_1.jpg", "url": "https://home.example/files/e1",
                                    "og": ["title": "IMG_1.jpg", "image": ["url": "https://home.example/files/e1", "width": 1600, "height": 1200]]]
    private let pending: JSONValue = ["embed_id": "e2", "kind": "upload"]
    private let link: JSONValue = ["kind": "link", "url": "https://git.example/wiki", "og": ["title": "Release 0.2"]]

    func testTilesNameEachEmbedAsTheWebDoes() {
        let tiles = MessageEdit(message([photo, pending, link, ["kind": "link", "url": "https://bare.example/x"], ["kind": "terminal"],
                                         ["kind": "append"], ["kind": "iframe"], "not an object"])).tiles
        XCTAssertEqual(tiles.map(\.name), ["IMG_1.jpg", "File", "Release 0.2", "bare.example", "Terminal", "Live text", "iframe"])
        XCTAssertEqual(tiles.map(\.id), [0, 1, 2, 3, 4, 5, 6])
        XCTAssertEqual(tiles.map(\.detail), ["1600 × 1200", "Uploading…", "git.example", "bare.example", "Live terminal", "Still arriving", "Embedded page"])
        let files = MessageEdit(message([["kind": "upload", "title": "notes.pdf", "url": "https://home.example/f/1"],
                                         ["kind": "upload", "title": "README", "url": "https://home.example/f/2"]])).tiles
        XCTAssertEqual(files.map(\.detail), ["PDF file", "File"])
        XCTAssertEqual(tiles.map(\.renamable), [true, true, false, false, false, false, false], "only an upload's title is the sender's")
        XCTAssertEqual(tiles.map(\.removeQuestion), [
            "Remove this attachment? Its file will be deleted.", "Remove this attachment? Its file will be deleted.", nil, nil,
            "Stop this live terminal? Its output so far will be deleted.", "Stop this live text? The text that has arrived so far will be dropped.", nil,
        ])
    }

    func testASaveSendsTheKeptEmbedsRenamedAndTheReplyUnlessRemoved() {
        var edit = MessageEdit(message([photo, pending, link]))
        edit.rename(edit.tiles[0], to: "  the red pot.jpg ")
        edit.remove(edit.tiles[2])
        XCTAssertEqual(edit.tiles.map(\.name), ["the red pot.jpg", "File"])
        let saved = edit.saved(text: "Two of mine, renamed", mentions: [])
        XCTAssertEqual(saved.body?.serialized(), #"{"embeds":[{"embed_id":"e1","kind":"upload","og":{"image":{"height":1200,"url":"https://home.example/files/e1","width":1600},"title":"the red pot.jpg"},"title":"the red pot.jpg","url":"https://home.example/files/e1"},{"embed_id":"e2","kind":"upload"}],"format":"plain","text":"Two of mine, renamed"}"#,
                       "og.title follows a title it showed; body.mentions goes with none")
        XCTAssertEqual(saved.replyTo, LogID("150"))
        XCTAssertEqual(saved.ext, ["k": 1])

        edit.removesReply = true
        XCTAssertNil(edit.saved(text: "x", mentions: ["ada"]).replyTo)
        XCTAssertEqual(edit.saved(text: "x", mentions: ["ada"]).body?["mentions"], ["ada"])
    }

    func testRenamingBackOrToNothingAndRenamingALinkChangeNothing() {
        var edit = MessageEdit(message([photo, link]))
        edit.rename(edit.tiles[0], to: "new.jpg")
        edit.rename(edit.tiles[0], to: "IMG_1.jpg")
        edit.rename(edit.tiles[0], to: "   ")
        edit.rename(edit.tiles[1], to: "My link")
        XCTAssertEqual(edit, MessageEdit(message([photo, link])))
        XCTAssertEqual(edit.saved(text: "Two of mine", mentions: ["ada"]).body, message([photo, link]).body)
    }

    func testRemovingEveryEmbedDropsTheKeyAndTheEditNeedsText() {
        var edit = MessageEdit(message([photo]))
        edit.remove(edit.tiles[0])
        XCTAssertEqual(edit.saved(text: "only text", mentions: []).body, ["text": "only text", "format": "plain"])
        XCTAssertFalse(DraftField(mode: .edit(edit), text: " ").canSend(readyFiles: 0, preparing: false), "a message needs text or an embed")
        XCTAssertTrue(DraftField(mode: .edit(MessageEdit(message([photo]))), text: "").canSend(readyFiles: 0, preparing: false),
                      "an edit may keep only its embeds")
        XCTAssertFalse(DraftField(mode: .edit(MessageEdit(message([]))), text: "").canSend(readyFiles: 0, preparing: false))
    }

    func testAStagedFileGoesUnderTheNameGivenEvenWhenRenamedWhilePreparing() {
        var draft = ComposerDraft(files: [StagedFile(name: "IMG_4023.HEIC", phase: .preparing)])
        draft.files[0].rename(to: " lid ")
        draft.files[0].rename(to: "")
        XCTAssertEqual(draft.files[0].shownName, "lid")
        draft.ready(draft.files[0].id, as: Attachment(fileURL: URL(filePath: "/tmp/IMG_4023.jpg"), title: "IMG_4023.jpg", contentType: "image/jpeg", byteCount: 9))
        XCTAssertEqual(draft.files[0].attachment?.title, "lid", "the upload's title")
        XCTAssertEqual(ServerSession.uploadEmbed(draft.files[0].attachment!), ["kind": "upload", "title": "lid"])

        let untouched = StagedFile(name: "IMG_1.HEIC", phase: .ready(Attachment(fileURL: URL(filePath: "/tmp/IMG_1.jpg"), title: "IMG_1.jpg", contentType: "image/jpeg", byteCount: 9)))
        XCTAssertEqual(untouched.shownName, "IMG_1.jpg", "the fitted file's name")
    }
}
