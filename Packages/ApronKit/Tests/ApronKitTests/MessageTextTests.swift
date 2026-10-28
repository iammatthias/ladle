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
}
