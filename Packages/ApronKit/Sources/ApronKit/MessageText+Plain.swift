import Foundation

extension MessageText {
    /// A body as plain text for where it is not rendered (a reply's quote, a one-line preview),
    /// as apron-web's `plainTextOf`: a `markdown` body without its syntax, so `**0 errors**` reads
    /// "0 errors", code keeps what is in it and a link shows its text, with each block on its own
    /// line and typed line breaks kept (`breaks: true`). Any other format is the text as written.
    /// Mentions stay as written, and bidirectional overrides are dropped (§3.5.2).
    public static func plain(_ body: JSONValue?) -> String {
        let text = TextDirection.withoutOverrides(body?["text"]?.stringValue ?? "")
        guard !text.isEmpty, body?["format"]?.stringValue == "markdown" else { return text }
        let breaking = text.replacingOccurrences(of: "\n", with: "  \n")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        guard let parsed = try? AttributedString(markdown: breaking, options: options) else { return text }
        var out = ""
        var block: Int?
        for run in parsed.runs {
            let id = run.presentationIntent?.components.first?.identity
            if let block, id != block { out += "\n" }
            block = id
            out += String(parsed[run.range].characters)
        }
        let lines = out.split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// The first `lines` non-empty lines of `plain`, cut to about `max` characters, as apron-web's
    /// `messageSnippet`: one line of about 120 for a reply's quote, three of about 280 for a card.
    public static func snippet(_ body: JSONValue?, lines: Int = 1, max: Int = 120) -> String {
        let kept = plain(body).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let text = kept.prefix(lines).joined(separator: "\n")
        guard text.count > max else { return text }
        return text.prefix(max - 1).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
