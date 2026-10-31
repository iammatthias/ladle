import ApronKit
import XCTest

/// The blocks a markdown body renders as, after apron-web's `markdown.test.ts`, written out as a
/// small markup so each assertion reads as the rendered result.
final class MessageBlocksTests: XCTestCase {
    private func md(_ text: String, emoji: EmojiCatalog? = nil, mentions: [String: String] = [:]) -> String {
        Self.markup(MessageText.blocks(["text": .string(text), "format": "markdown"], emoji: emoji, mentions: mentions))
    }

    static func markup(_ blocks: [MessageBlock]) -> String {
        blocks.map { block in
            switch block {
            case .paragraph(let text): "<p>\(inline(text))</p>"
            case .heading(let level, let text): "<h\(level)>\(inline(text))</h\(level)>"
            case .quote(let inner): "<blockquote>\(markup(inner))</blockquote>"
            case .list(let ordered, let start, let items):
                (ordered ? "<ol start=\(start)>" : "<ul>") + items.map { "<li>\(markup($0))</li>" }.joined() + (ordered ? "</ol>" : "</ul>")
            case .code(let language, let text): "<pre\(language.map { " lang=\($0)" } ?? "")>\(text)</pre>"
            case .rule: "<hr>"
            case .table(let table):
                "<table " + table.alignments.map { "\($0)" }.joined(separator: ",") + ">"
                    + "<tr>" + table.header.map { "<th>\(inline($0))</th>" }.joined() + "</tr>"
                    + table.rows.map { "<tr>" + $0.map { "<td>\(inline($0))</td>" }.joined() + "</tr>" }.joined() + "</table>"
            case .image(let image): "<img \(image.url.absoluteString) alt=\"\(image.alt)\">"
            }
        }.joined()
    }

    static func inline(_ text: AttributedString) -> String {
        text.runs.map { run in
            var out = String(text[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) { out = "`\(out)`" }
            if intent.contains(.stronglyEmphasized) { out = "**\(out)**" }
            if intent.contains(.emphasized) { out = "*\(out)*" }
            if intent.contains(.strikethrough) { out = "~~\(out)~~" }
            if let key = run[CustomEmojiKey.self] { out = "{emoji \(key)}" }
            if let chip = run[MentionKey.self] { out = "{@\(chip.userID)}" }
            if let link = run.link { out = "[\(out)](\(link.absoluteString))" }
            return out
        }.joined()
    }

    func testATypedLineBreakStaysInItsParagraphAndParagraphsStayApart() {
        XCTAssertEqual(md("Deploy plan\nWe cut at 14:00"), "<p>Deploy plan\nWe cut at 14:00</p>")
        XCTAssertEqual(md("one\n\ntwo"), "<p>one</p><p>two</p>")
        XCTAssertEqual(md("```\na\nb\n```"), "<pre>a\nb</pre>")
        XCTAssertEqual(md("hard  \nbreak"), "<p>hard\nbreak</p>")
    }

    func testEveryBlockCommonMarkHas() {
        XCTAssertEqual(md("# One *two*\n### Three"), "<h1>One *two*</h1><h3>Three</h3>")
        XCTAssertEqual(md("> quoted **bold**\n> more\n\nafter"), "<blockquote><p>quoted **bold**\nmore</p></blockquote><p>after</p>")
        XCTAssertEqual(md("- a\n- b\n  1. nested"), "<ul><li><p>a</p></li><li><p>b</p><ol start=1><li><p>nested</p></li></ol></li></ul>")
        XCTAssertEqual(md("3. x\n4. y"), "<ol start=3><li><p>x</p></li><li><p>y</p></li></ol>")
        XCTAssertEqual(md("```swift\nlet x = 1\n  indented\n```"), "<pre lang=swift>let x = 1\n  indented</pre>")
        XCTAssertEqual(md("    indented code"), "<pre>indented code</pre>")
        XCTAssertEqual(md("a\n\n---\n\nb"), "<p>a</p><hr><p>b</p>")
        XCTAssertEqual(md("~~gone~~ and `code`"), "<p>~~gone~~ and `code`</p>")
    }

    func testAGFMTableKeepsAlignmentAndInlineMarkdownPadsShortRowsAndDropsExtraCells() {
        XCTAssertEqual(md("| Name | Count |\n| :-- | --: |\n| **a** | 1 |\n| b |"),
                       "<table leading,trailing><tr><th>Name</th><th>Count</th></tr><tr><td>**a**</td><td>1</td></tr><tr><td>b</td><td></td></tr></table>")
        XCTAssertEqual(md("| a |\n| - |"), "<table leading><tr><th>a</th></tr></table>", "a header-only table has no body")
        XCTAssertEqual(md("| a |\n| - |\n| 1 | 2 |"), "<table leading><tr><th>a</th></tr><tr><td>1</td></tr></table>")
        XCTAssertEqual(md("| a | b |\n| :-: | - |\n| 1 | 2 |"), "<table center,leading><tr><th>a</th><th>b</th></tr><tr><td>1</td><td>2</td></tr></table>")
    }

    func testATableAfterAParagraphInsideAQuoteOrAListItem() {
        XCTAssertEqual(md("Results\na | b\n--|--\n1 | 2"), "<p>Results</p><table leading,leading><tr><th>a</th><th>b</th></tr><tr><td>1</td><td>2</td></tr></table>")
        XCTAssertEqual(md("> | a |\n> |---|"), "<blockquote><table leading><tr><th>a</th></tr></table></blockquote>")
        XCTAssertEqual(md("- item\n\n  | a |\n  |---|"), "<ul><li><p>item</p><table leading><tr><th>a</th></tr></table></li></ul>")
    }

    func testAnEscapedPipeIsALiteralMentionsAreMarkedInCellsAndCellsStaySafe() {
        XCTAssertEqual(md("| cmd | who |\n|---|---|\n| `a \\| b` | @alice |", mentions: ["alice": "Alice"]),
                       "<table leading,leading><tr><th>cmd</th><th>who</th></tr><tr><td>`a | b`</td><td>{@alice}</td></tr></table>")
        XCTAssertEqual(md("| a | b |\n|---|---|\n| <img src=x onerror=alert(1)> | [x](javascript:alert(1)) |"),
                       "<table leading,leading><tr><th>a</th><th>b</th></tr><tr><td><img src=x onerror=alert(1)></td><td>x</td></tr></table>")
    }

    func testPipesThatAreNoTableStayText() {
        XCTAssertEqual(md("a | b"), "<p>a | b</p>")
        XCTAssertEqual(md("| a | b |\n| --- |"), "<p>| a | b |\n| --- |</p>")
        XCTAssertEqual(md("```\n| a |\n|---|\n```"), "<pre>| a |\n|---|</pre>")
    }

    func testRawHTMLShowsAsTextInEveryBlock() {
        XCTAssertEqual(md("<script>alert(1)</script>"), "<p><script>alert(1)</script></p>")
        XCTAssertEqual(md("hi <b onmouseover=alert(1)>there</b>"), "<p>hi <b onmouseover=alert(1)>there</b></p>")
        XCTAssertEqual(md("> <script>alert(1)</script>"), "<blockquote><p><script>alert(1)</script></p></blockquote>")
        XCTAssertEqual(md("- <img src=x onerror=alert(1)>"), "<ul><li><p><img src=x onerror=alert(1)></p></li></ul>")
        XCTAssertEqual(md("# <span style=\"color:red\">x</span>"), "<h1><span style=\"color:red\">x</span></h1>")
        XCTAssertEqual(md("<div>block</div>\n\nafter"), "<p><div>block</div></p><p>after</p>")
    }

    func testUnsafeSchemesAreNeitherLinkedNorLoaded() {
        for source in ["[x](javascript:alert(1))", "[x](JaVaScRiPt:alert(1))", "[x](vbscript:msgbox(1))", "[x](data:text/html;base64,PHNjcmlwdD4=)"] {
            XCTAssertEqual(md(source), "<p>x</p>", source)
        }
        XCTAssertEqual(md("![x](javascript:alert(1))"), "<p>x</p>", "an image on another scheme is its alt text")
    }

    func testMarkdownImagesAreBlocksOfTheirOwn() {
        XCTAssertEqual(md("![embedded image from an external host](https://shazow.net/images/icon.png)"),
                       "<img https://shazow.net/images/icon.png alt=\"embedded image from an external host\">")
        XCTAssertEqual(md("![](https://evildomain.example.com/image.png)"), "<img https://evildomain.example.com/image.png alt=\"\">")
        XCTAssertEqual(md("look ![cat](https://chat.example/cat.png) here"), "<p>look </p><img https://chat.example/cat.png alt=\"cat\"><p> here</p>")
        XCTAssertEqual(md("![ref][r]\n\n[r]: https://tracker.example/r.png"), "<img https://tracker.example/r.png alt=\"ref\">")
        XCTAssertEqual(md("- ![a](https://chat.example/a.png)"), "<ul><li><img https://chat.example/a.png alt=\"a\"></li></ul>")
        XCTAssertEqual(md("[![badge](https://tracker.example/b.svg)](https://example.com)"), "<p>[badge](https://example.com)</p>",
                       "a linked image is its link, never media in a link")
    }

    func testBareLinksMentionsAndCustomEmojiStayOutOfCode() {
        let catalog = EmojiCatalog(json: [":a:": ["url": "https://chat.example/e/a"], ":b:": ["url": "https://chat.example/e/b"]])
        XCTAssertEqual(md("`:a:` and\n\n```\n:b:\n```", emoji: catalog), "<p>`:a:` and</p><pre>:b:</pre>")
        XCTAssertEqual(md("**https://example.com**"), "<p>[**https://example.com**](https://example.com)</p>")
        XCTAssertEqual(md("```\nhttps://example.com\n```"), "<pre>https://example.com</pre>")
        XCTAssertEqual(md("`@alice` @alice", mentions: ["alice": "Alice"]), "<p>`@alice` {@alice}</p>")
        XCTAssertEqual(md("# Ship :a:\n\n> (see https://example.com/x).", emoji: catalog),
                       "<h1>Ship {emoji :a:}</h1><blockquote><p>(see [https://example.com/x](https://example.com/x)).</p></blockquote>")
    }

    func testAPlainBodyIsOneParagraphAsWritten() {
        XCTAssertEqual(Self.markup(MessageText.blocks(["text": "# not a heading\n- nor a list"])), "<p># not a heading\n- nor a list</p>")
        XCTAssertEqual(MessageText.blocks(["text": ""]), [])
    }

    func testFlattenedBlocksKeepEveryLinkAndCodeBlock() {
        let body: JSONValue = ["text": "# [docs](https://a.example)\n\n```\ntoken-1\n```\n\n| x |\n|---|\n| https://b.example |", "format": "markdown"]
        XCTAssertEqual(MessageText.links(body).map(\.absoluteString), ["https://a.example", "https://b.example"])
        XCTAssertEqual(MessageText.code(body), ["token-1"])
    }
}
