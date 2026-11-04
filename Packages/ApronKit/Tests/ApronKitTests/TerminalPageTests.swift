@testable import ApronKit
import Foundation
import XCTest

/// After apron-web's `terminal-page.test.ts` (#207).
@MainActor
final class TerminalPageTests: XCTestCase {
    private func page(_ stream: String, _ title: String? = nil) -> String? {
        TerminalPage.url(stream: URL(string: stream), title: title)?.absoluteString
    }

    func testItPutsTheStreamAndItsTitleAfterTheHashOfTerminalApronChat() {
        XCTAssertEqual(page("https://chat.example/live/1"), "https://terminal.apron.chat/#stream=https://chat.example/live/1")
        XCTAssertEqual(page("https://chat.example/live/1", "make test"), "https://terminal.apron.chat/#stream=https://chat.example/live/1&title=make%20test")
    }

    func testItEncodesWhatWouldEndAKeyAndDropsTheStreamsOwnFragment() throws {
        let link = try XCTUnwrap(page("https://chat.example/live?id=1&key=a+b%2F#x", "a & b #1"))
        XCTAssertEqual(link, "https://terminal.apron.chat/#stream=https://chat.example/live%3Fid%3D1%26key%3Da%2Bb%252F&title=a%20%26%20b%20%231")
        let keys = try XCTUnwrap(URLComponents(string: "?" + (URL(string: link)?.fragment(percentEncoded: true) ?? ""))?.queryItems)
        XCTAssertEqual(keys.map(\.name), ["stream", "title"])
        XCTAssertEqual(keys.map(\.value), ["https://chat.example/live?id=1&key=a+b%2F", "a & b #1"])
    }

    /// Ladle's `Embed` keeps only a string `title`, so the web's number and object titles arrive as nil.
    func testItLeavesOutATitleThatIsMissingOrBlank() throws {
        XCTAssertEqual(page("https://chat.example/live/1", "   "), "https://terminal.apron.chat/#stream=https://chat.example/live/1")
        XCTAssertEqual(page("https://chat.example/live/1", "  make test "), "https://terminal.apron.chat/#stream=https://chat.example/live/1&title=make%20test")
        let embed = try XCTUnwrap(Embed(["kind": "terminal", "title": 5, "url": "https://chat.example/live/1"]))
        XCTAssertEqual(TerminalPage.url(stream: embed.url, title: embed.title)?.absoluteString, "https://terminal.apron.chat/#stream=https://chat.example/live/1")
    }

    func testThereIsNoneForAStreamThePageWouldNotRead() {
        XCTAssertNil(TerminalPage.url(stream: nil))
        for stream in ["", "not a url", "http://chat.example/live/1", "http://localhost:8080/live/1", "https://ada:pw@chat.example/live/1", "data:text/plain,hi"] {
            XCTAssertNil(page(stream), stream)
        }
    }

    func testACardOffersItForAStreamFromItsServerFinishedOrNot() async throws {
        let store = await PreviewFixtures.makeStore()
        let home = try XCTUnwrap(store.session(for: PreviewFixtures.homeID))
        let live = try XCTUnwrap(Embed(["kind": "terminal", "title": "make ramp", "url": .string(PreviewFixtures.liveTerminalURL.absoluteString)]))
        XCTAssertEqual(home.terminalPage(of: live)?.absoluteString, "https://terminal.apron.chat/#stream=https://home.example/live/ramp&title=make%20ramp")
        let finished = try XCTUnwrap(Embed(["kind": "terminal", "title": "make ramp", "url": .string(PreviewFixtures.liveTerminalURL.absoluteString), "output": "done\r\n"]))
        XCTAssertEqual(home.terminalPage(of: finished), home.terminalPage(of: live), "its output kept, it still links to the stream")
        XCTAssertNil(home.terminalPage(of: try XCTUnwrap(Embed(["kind": "terminal", "url": "https://elsewhere.example/live/1"]))), "a url from another origin")
        XCTAssertNil(home.terminalPage(of: try XCTUnwrap(Embed(["kind": "terminal", "title": "make soak"]))), "no url yet")
        XCTAssertNil(home.terminalPage(of: try XCTUnwrap(Embed(["kind": "append", "url": .string(PreviewFixtures.liveTerminalURL.absoluteString)]))))
    }
}
