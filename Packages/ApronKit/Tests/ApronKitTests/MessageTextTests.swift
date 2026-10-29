@testable import ApronKit
import XCTest

final class MessageTextTests: XCTestCase {
    /// Each linked run's text and target.
    private func links(_ text: String, markdown: Bool = false) -> [String] {
        var body: [String: JSONValue] = ["text": .string(text)]
        if markdown { body["format"] = "markdown" }
        let out = MessageText.attributed(.object(body))
        return out.runs.compactMap { run in
            run.link.map { "\(String(out[run.range].characters)) -> \($0.absoluteString)" }
        }
    }

    func testAprondPlainMessageLinksItsURLs() throws {
        let frame = try JSONValue(parsing: #"{"body":{"text":"see https://github.com/apron-chat/apron/pull/12 and apron:?room=general."},"from":{"name":"probe","user_id":"guest_1"},"log_id":"1793226711492","message_id":"1793226711492","room_id":"general"}"#)
        let message = try XCTUnwrap(Records(messageParams: frame).messages.first)
        XCTAssertEqual(MessageText.links(message.body).map(\.absoluteString),
                       ["https://github.com/apron-chat/apron/pull/12", "apron:?room=general"])
    }

    func testAnInviteDeviceNoticeHasItsLinkAndItsCodeToCopy() {
        let link = "https://link.apron.chat/#server=wss%3A%2F%2Fserver.apron.chat&token=apron_dev_abc"
        let text = [
            "This token signs in as you (`ada_1`) on your device **phone**. Keep it secret.",
            "```\napron_dev_abc\n```",
            "Or open this link on **phone**, which signs you in there with any Apron app: <\(link)>",
        ].joined(separator: "\n\n")
        let body: JSONValue = ["text": .string(text), "format": "markdown"]
        XCTAssertEqual(MessageText.links(body), [URL(string: link)!])
        XCTAssertEqual(MessageText.code(body), ["ada_1", "apron_dev_abc"])
    }

    func testBareLinksAsApronWebFindsThem() {
        XCTAssertEqual(links("go to http://example.com"), ["http://example.com -> http://example.com"])
        XCTAssertEqual(links("see https://example.com/a?b=1&c=2 now", markdown: true),
                       ["https://example.com/a?b=1&c=2 -> https://example.com/a?b=1&c=2"])
        XCTAssertEqual(links("see apron:?room=ops&message=1 now"), ["apron:?room=ops&message=1 -> apron:?room=ops&message=1"])
        XCTAssertEqual(links("(see https://example.com/x)."), ["https://example.com/x -> https://example.com/x"])
        XCTAssertEqual(links("https://en.wikipedia.org/wiki/Foo_(bar), ok"),
                       ["https://en.wikipedia.org/wiki/Foo_(bar) -> https://en.wikipedia.org/wiki/Foo_(bar)"])
        XCTAssertEqual(links(#""https://example.com""#), ["https://example.com -> https://example.com"])
        XCTAssertEqual(links("HTTPS://Example.com/x!"), ["HTTPS://Example.com/x -> HTTPS://Example.com/x"])
    }

    func testTextThatIsNotALinkStaysText() {
        for text in ["web+apron:?room=ops.", "xapron:?room=ops", "my_apron:?room=ops", "x-apron:?room=ops", "a.apron:?room=ops",
                     "apron: is a scheme", "javascript:alert(1) ftp://example.com https://", "www.example.com", "xhttps://example.com"] {
            XCTAssertEqual(links(text), [], text)
        }
    }

    func testMarkdownLinksCodeAndAutolinks() {
        XCTAssertEqual(links("[docs](https://example.com)", markdown: true), ["docs -> https://example.com"])
        XCTAssertEqual(links("<https://example.com>", markdown: true), ["https://example.com -> https://example.com"])
        XCTAssertEqual(links("**https://example.com**", markdown: true), ["https://example.com -> https://example.com"])
        XCTAssertEqual(links("[ops](apron:?room=ops)", markdown: true), ["ops -> apron:?room=ops"])
        XCTAssertEqual(links("`https://example.com`", markdown: true), [])
        XCTAssertEqual(links("[x](javascript:alert(1)) [y](shortcuts://run-shortcut?name=x)", markdown: true), [])
    }

    func testAprondLinkEmbedHasNoOpenGraph() throws {
        let frame = try JSONValue(parsing: #"{"body":{"embeds":[{"embed_id":"embed_1","kind":"link","url":"https://github.com/apron-chat/apron/pull/12"}],"text":"with embed https://github.com/apron-chat/apron/pull/12"},"from":{"name":"probe","user_id":"guest_1"},"log_id":"1793226711494","message_id":"1793226711494","room_id":"general"}"#)
        let embed = try XCTUnwrap(Records(messageParams: frame).messages.first?.embedList.first)
        XCTAssertEqual(embed.kind, "link")
        XCTAssertEqual(embed.url?.absoluteString, "https://github.com/apron-chat/apron/pull/12")
        XCTAssertNil(embed.og)
        XCTAssertNil(embed.upload)
    }

    func testLinkEmbedWithOpenGraph() throws {
        let value = try JSONValue(parsing: #"{"kind":"link","url":"https://chat.example/pr/42","og":{"site_name":"git.example","title":"Ladle glyph","description":"Bowl-only mark.","image":{"url":"https://chat.example/f/Zr8Tq1/thumb","type":"image/webp","width":1200,"height":630,"alt":"The glyph"}}}"#)
        let og = try XCTUnwrap(Embed(value)?.og)
        XCTAssertEqual([og.siteName, og.title, og.description, og.image?.alt], ["git.example", "Ladle glyph", "Bowl-only mark.", "The glyph"])
        XCTAssertEqual(og.image?.url.absoluteString, "https://chat.example/f/Zr8Tq1/thumb")
    }

    private func markdown(_ text: String) -> JSONValue { ["text": .string(text), "format": "markdown"] }

    func testAMarkdownMessageQuotesAsPlainTextWithCodeKeptAndALinkByItsText() {
        XCTAssertEqual(MessageText.snippet(markdown("Tabulated `log₁₀` to 7 places. **0 errors**, 4,000 gears turned.")),
                       "Tabulated log₁₀ to 7 places. 0 errors, 4,000 gears turned.")
        XCTAssertEqual(MessageText.snippet(markdown("_see_ [the notes](https://example.com/notes) for **@bob**, a < b & c")),
                       "see the notes for @bob, a < b & c")
        XCTAssertEqual(MessageText.snippet(markdown("**ping** `@you`")), "ping @you")
        XCTAssertEqual(MessageText.plain(markdown("> quoted *line*")), "quoted line")
    }

    func testPlainTextTakesBlocksAsLinesAndKeepsTypedLineBreaks() {
        let body = markdown("# Plan\n\n- ~~one~~ first\n- two\n\n```\nx = 1\n```")
        XCTAssertEqual(MessageText.snippet(body, lines: 3, max: 280), "Plan\none first\ntwo")
        XCTAssertEqual(MessageText.plain(body), "Plan\none first\ntwo\nx = 1")
        XCTAssertEqual(MessageText.plain(markdown("a\nb\n\n\nc")), "a\nb\nc")
        XCTAssertEqual(MessageText.snippet(markdown("first\nsecond")), "first")
    }

    func testAPlainMessageQuotesAsWrittenAndALongOneIsCut() {
        XCTAssertEqual(MessageText.snippet(["text": "Tabulated `log₁₀`, **as typed**"]), "Tabulated `log₁₀`, **as typed**")
        XCTAssertEqual(MessageText.snippet(["text": "  one  \n\n two "], lines: 2), "one\ntwo")
        XCTAssertEqual(MessageText.plain(markdown("")), "")
        XCTAssertEqual(MessageText.snippet(["text": .string(String(repeating: "ab ", count: 10))], max: 10), "ab ab ab…")
    }
}
