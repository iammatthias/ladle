import XCTest
@testable import ApronKit

/// What a v10 server's live text looks like once it ends (v10 §4.8.5, §4.8.6), read by a client
/// that does not follow it live.
@MainActor
final class FinishedLiveTextTests: XCTestCase {
    private func message(_ body: JSONValue) -> MessageSnapshot {
        MessageSnapshot(messageID: LogID("1724803700000")!, logID: LogID("1724803760000")!, roomID: "general",
                        from: UserObject(["user_id": "ada", "name": "Ada"])!, body: body)
    }

    func testAFinishedTerminalShowsItsOutputAsATerminalWould() throws {
        let finished = try XCTUnwrap(Embed(["embed_id": "embed_1234", "kind": "terminal", "title": "make test",
                                            "output": "\u{1B}[32mok\u{1B}[0m  42 tests  0.41s\r\n"]))
        XCTAssertEqual(TerminalScreen.showing(finished.output ?? "").plainText, "ok  42 tests  0.41s")
        XCTAssertEqual(finished.kindLabel, "Terminal")
        XCTAssertFalse(finished.isLiveText)
        let live = try XCTUnwrap(Embed(["embed_id": "embed_1234", "kind": "terminal", "title": "make test", "url": "https://chat.example/t/p3Wn9d"]))
        XCTAssertNil(live.output)
        XCTAssertTrue(live.isLiveText, "a terminal without output is live; its screen reads url (LiveText)")
    }

    func testAnAppendShowsNoCardLiveAndTheMergedTextOnceFinished() async throws {
        let store = await PreviewFixtures.makeStore()
        let home = try XCTUnwrap(store.session(for: PreviewFixtures.homeID))
        let live = MessageRowModel(message(["text": "Here is the plan:\n\n", "format": "markdown",
                                            "embeds": [["embed_id": "embed_1300", "kind": "append", "url": "https://chat.example/a/Vb2k"]]]), in: home)
        XCTAssertEqual(live.embeds.count, 0, "no fallback card for the live text")
        XCTAssertEqual(String(MessageBlock.flattened(live.blocks).characters), "Here is the plan:")
        let finished = MessageRowModel(message(["text": "Here is the plan:\n\n1. Roll back.\n2. Renew the cert.\n", "format": "markdown"]), in: home)
        XCTAssertEqual(String(MessageBlock.flattened(finished.blocks).characters), "Here is the plan:\nRoll back.\nRenew the cert.")
    }

    func testAMessageWithoutTextReadsAsItsEmbedsInPreviews() {
        XCTAssertEqual(MessageText.embedsLabel(["text": "", "embeds": [["kind": "append", "url": "https://chat.example/a/1"]]]), "Live text")
        XCTAssertEqual(MessageText.embedsLabel(["embeds": [["kind": "terminal", "title": " make\n test "]]]), "Terminal: make test")
        XCTAssertEqual(MessageText.embedsLabel(["embeds": [["kind": "terminal"]]]), "Terminal")
        XCTAssertEqual(MessageText.embedsLabel(["embeds": [["kind": "upload", "title": "a.png"]]]), "Attachment")
        XCTAssertNil(MessageText.embedsLabel(["text": "hi"]))
    }

    func testVersionsNineAndTenAreRead() {
        XCTAssertTrue(ServerInfo.supportedVersions.contains(9))
        XCTAssertTrue(ServerInfo.supportedVersions.contains(10))
        XCTAssertEqual(ServerInfo(params: ["apron": 10, "auth": ["guest"], "capabilities": ["embed:append", "embed:terminal"]])?.apron, 10)
    }
}
