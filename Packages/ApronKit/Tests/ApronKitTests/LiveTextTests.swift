import XCTest
@testable import ApronKit

/// Live text (v10 §4.8.5): the decoder, an append's edits, Markdown settled while it arrives,
/// and following a `url`, with apron-web's `live-text.test.ts` and `live-markdown.test.ts`
/// cases ported with their literal values. JavaScript's lone surrogate cases have no Swift
/// counterpart: a Swift string holds whole code points.
final class LiveTextTests: XCTestCase {
    private func edited(_ chunks: String...) -> String {
        var text = ""
        for chunk in chunks { LiveTextEdit.apply(chunk, to: &text) }
        return text
    }

    func testTheDecoderKeepsTheBOMJoinsACutCharacterAndReplacesBadBytes() {
        var decoder = LiveTextDecoder()
        let parts: [[UInt8]] = [[0xEF, 0xBB, 0xBF, 0x24, 0xE2, 0x82], [0xAC, 0x20, 0xC0, 0xAF], [0x20, 0xE2]]
        let text = parts.map { decoder.decode(Data($0)) }.joined() + decoder.finish()
        XCTAssertEqual(text, "\u{FEFF}$\u{20AC} \u{FFFD}\u{FFFD} \u{FFFD}")
        var emoji = LiveTextDecoder()
        XCTAssertEqual(emoji.decode(Data([0xF0, 0x9F])), "")
        XCTAssertEqual(emoji.decode(Data([0x9A, 0x80, 0x21])), "🚀!")
        var bad = LiveTextDecoder()
        XCTAssertEqual(bad.decode(Data([0x61, 0xE0, 0x80])), "a\u{FFFD}\u{FFFD}", "E0 80 can start no character, so nothing is held")
    }

    func testABackspaceRemovesTheCodePointBeforeIt() {
        XCTAssertEqual(edited("Ready.\u{08}!"), "Ready!")
        XCTAssertEqual(edited("caf\u{E9}\u{08}"), "caf")
        XCTAssertEqual(edited("ok 🚀\u{08}"), "ok ")
        XCTAssertEqual(edited("ok 🚀\u{08}\u{08}"), "ok")
        XCTAssertEqual(edited("cafe\u{301}\u{08}"), "cafe")
        XCTAssertEqual(edited("\u{08}\u{08}Hi"), "Hi")
    }

    func testAFormFeedClearsTheTextBeforeIt() {
        XCTAssertEqual(edited("Looking at the logs…\u{0C}"), "")
        XCTAssertEqual(edited("Draft one\u{0C}Draft two\u{0C}The plan"), "The plan")
        XCTAssertEqual(edited("Draft", " one", "\u{0C}The ", "plan\u{08}n"), "The plan")
    }

    func testEditsReachBackIntoTheTextKeptSoFar() {
        XCTAssertEqual(edited("Roll back the indx", "\u{08}", "ex"), "Roll back the index")
        XCTAssertEqual(edited("faield", "\u{08}\u{08}\u{08}led"), "failed")
        XCTAssertEqual(edited("🚀🚀", "\u{08}"), "🚀")
        XCTAssertEqual(edited("ab", "\u{08}\u{08}\u{08}\u{08}c"), "c")
        XCTAssertEqual(edited("abc", "de\u{08}\u{08}\u{08}"), "ab")
    }

    func testALargeChunkOfBackspacesTakesLinearTime() {
        let chunk = String(repeating: "aa\u{08}", count: 100_000)
        let began = ContinuousClock.now
        XCTAssertEqual(edited("kept", chunk), "kept" + String(repeating: "a", count: 100_000))
        XCTAssertLessThan(ContinuousClock.now - began, .seconds(2))
        XCTAssertEqual(edited("kept", chunk + String(repeating: "\u{08}", count: 100_002)), "ke")
        XCTAssertEqual(edited("kept", String(repeating: "\u{08}", count: 100_000) + chunk), String(repeating: "a", count: 100_000))
    }

    func testTextAlreadyEditedStaysAsItIs() {
        let raw = ["Here is the pla", "m\u{08}n:\u{0C}Here is the plan 🚀\u{08}", ": roll back"]
        let once = edited(raw[0], raw[1], raw[2])
        XCTAssertEqual(once, "Here is the plan : roll back")
        XCTAssertEqual(edited(once), once)
        XCTAssertEqual(edited(edited(raw[0], raw[1]), raw[2]), once)
    }

    func testMarkdownStillArrivingIsSettled() {
        for text in ["Plain text", "A **bold** word", "```\ncode\n```\n\nafter"] {
            XCTAssertEqual(LiveMarkdown.settle(text), text)
        }
        XCTAssertEqual(LiveMarkdown.settle("Run:\n\n```sh\nls **"), "Run:\n\n```sh\nls **\n```")
        XCTAssertEqual(LiveMarkdown.settle("~~~~\ncode"), "~~~~\ncode\n~~~~")
        XCTAssertEqual(LiveMarkdown.settle("````\n```\nx"), "````\n```\nx\n````")
        XCTAssertFalse(LiveMarkdown.settle("``` a ` b").contains("\n```"))
        XCTAssertEqual(LiveMarkdown.settle("Use `./migrate do"), "Use `./migrate do`")
        XCTAssertEqual(LiveMarkdown.settle("Use ``a ` b"), "Use ``a ` b``")
        XCTAssertEqual(LiveMarkdown.settle("Use `"), "Use ")
        XCTAssertEqual(LiveMarkdown.settle("Roll **back the"), "Roll **back the**")
        XCTAssertEqual(LiveMarkdown.settle("a ~~b **c"), "a ~~b **c**~~")
        XCTAssertEqual(LiveMarkdown.settle("a **b ~~c"), "a **b ~~c~~**")
        XCTAssertEqual(LiveMarkdown.settle("Roll **"), "Roll ")
        XCTAssertEqual(LiveMarkdown.settle("**done** and **"), "**done** and ")
        XCTAssertEqual(LiveMarkdown.settle("`a ** b` c"), "`a ** b` c")
        XCTAssertEqual(LiveMarkdown.settle("2 \\** 3"), "2 \\** 3")
        XCTAssertEqual(LiveMarkdown.settle("a ** b\n\nc"), "a ** b\n\nc")
        XCTAssertEqual(LiveMarkdown.settle("See [the docs](https://exa"), "See the docs")
        XCTAssertEqual(LiveMarkdown.settle("See ![chart](https://exa"), "See ")
        XCTAssertEqual(LiveMarkdown.settle("See [the do"), "See the do")
        XCTAssertEqual(LiveMarkdown.settle("See [the docs](https://example.com) now"), "See [the docs](https://example.com) now")
        XCTAssertEqual(LiveMarkdown.settle("Steps:\n-"), "Steps:")
        XCTAssertEqual(LiveMarkdown.settle("Steps:\n2."), "Steps:")
        XCTAssertEqual(LiveMarkdown.settle("Title\n=="), "Title")
        XCTAssertEqual(LiveMarkdown.settle("Steps:\n- one"), "Steps:\n- one")
    }

    func testTerminalFeedKeepsTheLastPartFromAControlCharacter() {
        XCTAssertEqual(TerminalFeed.keepLast("short", limit: 10), "short")
        XCTAssertEqual(TerminalFeed.keepLast("aaaa\nbbb\nccc", limit: 9), "\nbbb\nccc")
        XCTAssertEqual(TerminalFeed.keepLast("abcdefgh", limit: 3), "fgh")
    }

    func testARefusalOtherThan408And429IsFinal() {
        XCTAssertTrue(LiveTextRefused(status: 404).isDefinitive)
        XCTAssertTrue(LiveTextRefused(status: 403).isDefinitive)
        XCTAssertFalse(LiveTextRefused(status: 429).isDefinitive)
        XCTAssertFalse(LiveTextRefused(status: 408).isDefinitive)
        XCTAssertFalse(LiveTextRefused(status: 503).isDefinitive)
    }
}

/// Following a live text: a drop or failure tries again after 1 s, 2 s, … and a new response
/// starts over; a definitive refusal ends it; cancelling ends nothing.
@MainActor
final class LiveTextFollowTests: XCTestCase {
    private final class Script: @unchecked Sendable {
        var answers: [[Result<LiveTextEvent, LiveTextRefused>]]
        var asked = 0
        var waits: [Duration] = []
        init(_ answers: [[Result<LiveTextEvent, LiveTextRefused>]]) { self.answers = answers }

        var read: LiveTextRead {
            { [self] _ in
                AsyncThrowingStream { continuation in
                    let answer = asked < answers.count ? answers[asked] : []
                    asked += 1
                    for step in answer {
                        switch step {
                        case .success(let event): continuation.yield(event)
                        case .failure(let refusal): continuation.finish(throwing: refusal); return
                        }
                    }
                    continuation.finish()
                }
            }
        }

        var sleep: @Sendable (Duration) async throws -> Void { { [self] in waits.append($0) } }
    }

    private func follow(_ script: Script) async -> [String] {
        var calls: [String] = []
        var decoder = LiveTextDecoder()
        await LiveTextFollow.run(URL(string: "https://chat.example/live/1")!, read: script.read, sleep: script.sleep,
                                 started: { calls.append("start") }, bytes: { calls.append(decoder.decode($0)) }, ended: { calls.append("end") })
        return calls
    }

    func testAResponseThatEndsIsReadOnce() async {
        let script = Script([[.success(.started), .success(.bytes(Data("$ make\n".utf8))), .success(.bytes(Data("ok\n".utf8)))]])
        let calls = await follow(script)
        XCTAssertEqual(calls, ["start", "$ make\n", "ok\n", "end"])
        XCTAssertEqual(script.asked, 1)
    }

    func testFailuresWaitLongerEachTimeAndAReconnectStartsOver() async {
        let script = Script([
            [.failure(LiveTextRefused(status: 503))],
            [.failure(LiveTextRefused(status: 429, retryAfter: 5))],
            [.success(.started), .success(.bytes(Data("Here is ".utf8))), .failure(LiveTextRefused(status: 502))],
            [.success(.started), .success(.bytes(Data("Here is the plan".utf8)))],
        ])
        let calls = await follow(script)
        XCTAssertEqual(calls, ["start", "Here is ", "start", "Here is the plan", "end"])
        XCTAssertEqual(script.waits, [.seconds(1), .seconds(5), .seconds(1)], "a 429's Retry-After is the least wait; a drop after a start waits a second")
    }

    func testADefinitiveRefusalEndsAtOnce() async {
        let script = Script([[.failure(LiveTextRefused(status: 404))]])
        let calls = await follow(script)
        XCTAssertEqual(calls, ["end"])
        XCTAssertEqual(script.asked, 1)
    }
}
