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

    func testAFinishedTerminalShowsItsOutputWithoutEscapes() throws {
        let finished = try XCTUnwrap(Embed(["embed_id": "embed_1234", "kind": "terminal", "title": "make test",
                                            "output": "\u{1B}[32mok\u{1B}[0m  42 tests  0.41s\r\n"]))
        XCTAssertEqual(finished.terminalOutput, "ok  42 tests  0.41s")
        XCTAssertEqual(finished.kindLabel, "Terminal")
        let live = try XCTUnwrap(Embed(["embed_id": "embed_1234", "kind": "terminal", "title": "make test", "url": "https://chat.example/t/p3Wn9d"]))
        XCTAssertNil(live.terminalOutput, "live output is not read yet; the card links its url")
        XCTAssertNil(Embed(["kind": "link", "output": "x"])?.terminalOutput)
    }

    func testTerminalTextOverwritesOnCarriageReturnAndKeepsTheLastLines() {
        XCTAssertEqual(TerminalText.plain("Downloading  10%\rDownloading 100%\r\ndone\n\n"), "Downloading 100%\ndone")
        XCTAssertEqual(TerminalText.plain("abc\rX\n"), "Xbc", "a carriage return draws over, it does not clear")
        XCTAssertEqual(TerminalText.plain("\u{1B}]0;title\u{07}a\u{1B}[2K\u{1B}(Bb\tc\u{08}d"), "ab      d")
        XCTAssertEqual(TerminalText.plain((1...20).map(String.init).joined(separator: "\n"), maxLines: 3), "18\n19\n20")
        XCTAssertEqual(TerminalText.plain("\u{1B}P1;2q\u{1B}\\x"), "x", "a DCS string ends at ST")
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

    func testVersionsNineAndTenAreRead() {
        XCTAssertTrue(ServerInfo.supportedVersions.contains(9))
        XCTAssertTrue(ServerInfo.supportedVersions.contains(10))
        XCTAssertEqual(ServerInfo(params: ["apron": 10, "auth": ["guest"], "capabilities": ["embed:append", "embed:terminal"]])?.apron, 10)
    }
}
