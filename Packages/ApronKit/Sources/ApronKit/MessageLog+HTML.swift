import Foundation

extension MessageLog {
    /// A Markdown log rendered as HTML, as apron-web's `messageLogHtml` (#164): what Copy puts on
    /// the pasteboard beside the Markdown, so a rich editor (Notes, Mail) pastes it formatted and
    /// a plain one pastes the Markdown. Text is escaped; links keep only the schemes a message's
    /// own links may have.
    public static func html(_ log: String) -> String {
        render(MessageText.blocks(["text": .string(log), "format": "markdown"]))
    }

    private static func render(_ blocks: [MessageBlock]) -> String {
        blocks.map { block in
            switch block {
            case .paragraph(let text): "<p>\(inline(text))</p>"
            case .heading(let level, let text): "<h\(level)>\(inline(text))</h\(level)>"
            case .quote(let inner): "<blockquote>\(render(inner))</blockquote>"
            case .list(let ordered, let start, let items):
                (ordered ? (start == 1 ? "<ol>" : "<ol start=\"\(start)\">") : "<ul>")
                    + items.map { "<li>\(render($0))</li>" }.joined() + (ordered ? "</ol>" : "</ul>")
            case .code(_, let text): "<pre><code>\(escaped(text))</code></pre>"
            case .rule: "<hr>"
            case .table(let table): tableHTML(table)
            case .image(let image): "<p><img src=\"\(escaped(image.url.absoluteString))\" alt=\"\(escaped(image.alt))\"></p>"
            }
        }.joined()
    }

    private static func tableHTML(_ table: MessageTable) -> String {
        func row(_ tag: String, _ cells: [AttributedString]) -> String {
            let parts: [String] = cells.indices.map { cell(tag, cells[$0], table.alignments.indices.contains($0) ? table.alignments[$0] : nil) }
            return "<tr>" + parts.joined() + "</tr>"
        }
        let body: [String] = table.rows.map { row("td", $0) }
        return "<table><thead>" + row("th", table.header) + "</thead><tbody>" + body.joined() + "</tbody></table>"
    }

    private static func cell(_ tag: String, _ text: AttributedString, _ alignment: MessageTable.Alignment?) -> String {
        let align = switch alignment {
        case .center: " style=\"text-align:center\""
        case .trailing: " style=\"text-align:right\""
        default: ""
        }
        return "<\(tag)\(align)>\(inline(text))</\(tag)>"
    }

    private static func inline(_ text: AttributedString) -> String {
        text.runs.map { run in
            var out = escaped(String(text[run.range].characters)).replacingOccurrences(of: "\n", with: "<br>")
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) { out = "<code>\(out)</code>" }
            if intent.contains(.stronglyEmphasized) { out = "<strong>\(out)</strong>" }
            if intent.contains(.emphasized) { out = "<em>\(out)</em>" }
            if intent.contains(.strikethrough) { out = "<del>\(out)</del>" }
            if let link = run.link { out = "<a href=\"\(escaped(link.absoluteString))\">\(out)</a>" }
            return out
        }.joined()
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
