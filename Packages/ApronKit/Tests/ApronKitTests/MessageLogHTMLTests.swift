import ApronKit
import XCTest

final class MessageLogHTMLTests: XCTestCase {
    func testALogRendersAsHTMLWithItsTextEscaped() {
        let log = """
        ### #general · Today

        **Ada** · 09:10
        Ship <b>Friday</b> & ~~Thursday~~, see https://home.example/wiki

        > ↪ **Bram**: `make check`…

        - one
        - two
        """
        XCTAssertEqual(MessageLog.html(log), """
        <h3>#general · Today</h3>\
        <p><strong>Ada</strong> · 09:10<br>Ship &lt;b&gt;Friday&lt;/b&gt; &amp; <del>Thursday</del>, see <a href="https://home.example/wiki">https://home.example/wiki</a></p>\
        <blockquote><p>↪ <strong>Bram</strong>: <code>make check</code>…</p></blockquote>\
        <ul><li><p>one</p></li><li><p>two</p></li></ul>
        """)
    }

    func testCodeTablesAndImagesKeepTheirShape() {
        XCTAssertEqual(MessageLog.html("```\na < b\n```"), "<pre><code>a &lt; b</code></pre>")
        XCTAssertEqual(MessageLog.html("| a | b |\n|:-:|--:|\n| 1 | 2 |"),
                       #"<table><thead><tr><th style="text-align:center">a</th><th style="text-align:right">b</th></tr></thead><tbody><tr><td style="text-align:center">1</td><td style="text-align:right">2</td></tr></tbody></table>"#)
        XCTAssertEqual(MessageLog.html("![a \"pot\"](https://home.example/pot.jpg)"),
                       #"<p><img src="https://home.example/pot.jpg" alt="a &quot;pot&quot;"></p>"#)
    }
}
