import Foundation

/// A message body's text as styled runs with its links, as apron-web renders it (§3.5.2):
/// `markdown` as inline CommonMark with raw HTML left as text, and in either format each bare
/// `http(s)` URL and §A.4 `apron:?` link linked, except inside code and existing links. A link
/// whose scheme apron-web would not link (`javascript:`, another app's) is dropped. Bidirectional
/// overrides are dropped too (§3.5.2). With a custom emoji catalog, each key it has outside code
/// and links carries `CustomEmojiKey`, for the app to show as the emoji's image. With `rooms`,
/// each `#room_id` outside code and links (Appendix A.3) that it gives a title for shows as
/// `#title`, carries `RoomReferenceKey`, and links to the room, as apron-web's room chips; any
/// other `#word` stays text.
public enum MessageText {
    /// CommonMark that isn't a message, such as a room's `description` or `server.welcome`.
    public static func markdown(_ text: String, emoji: EmojiCatalog? = nil) -> AttributedString {
        attributed(["text": .string(text), "format": "markdown"], emoji: emoji)
    }

    public static func attributed(_ body: JSONValue?, emoji: EmojiCatalog? = nil, rooms: ((String) -> String?)? = nil) -> AttributedString {
        let text = TextDirection.withoutOverrides(body?["text"]?.stringValue ?? "")
        var out = AttributedString(text)
        if body?["format"]?.stringValue == "markdown" {
            let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            out = (try? AttributedString(markdown: text, options: options)) ?? out
        }
        var bare: [(offset: Int, length: Int, url: URL)] = []
        var unsafe: [Range<AttributedString.Index>] = []
        for run in out.runs {
            if let link = run.link {
                if !linkable(link) { unsafe.append(run.range) }
                continue
            }
            if run.inlinePresentationIntent?.contains(.code) == true { continue }
            let runText = String(out[run.range].characters)
            let start = out.unicodeScalars.distance(from: out.startIndex, to: run.range.lowerBound)
            for (range, url) in bareLinks(in: runText) {
                bare.append((start + runText.unicodeScalars.distance(from: runText.startIndex, to: range.lowerBound),
                             runText.unicodeScalars.distance(from: range.lowerBound, to: range.upperBound), url))
            }
        }
        for range in unsafe { out[range].link = nil }
        for link in bare {
            let lower = out.unicodeScalars.index(out.startIndex, offsetBy: link.offset)
            out[lower ..< out.unicodeScalars.index(lower, offsetBy: link.length)].link = link.url
        }
        if let rooms { markRooms(in: &out, rooms) }
        if let emoji { markKeys(in: &out, emoji) }
        return out
    }

    /// Each `#room_id` that `title` names, outside code and links, as a chip: `#title`, linked.
    private static func markRooms(in out: inout AttributedString, _ title: (String) -> String?) {
        let text = String(out.characters)
        var chips: [(offset: Int, length: Int, id: String, title: String)] = []
        for match in RoomMentions.reference.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text), let idRange = Range(match.range(at: 1), in: text) else { continue }
            let id = String(text[idRange])
            guard let name = title(id) else { continue }
            chips.append((text.unicodeScalars.distance(from: text.startIndex, to: whole.lowerBound), text[whole].unicodeScalars.count, id, name))
        }
        for chip in chips.reversed() {
            let lower = out.unicodeScalars.index(out.startIndex, offsetBy: chip.offset)
            let range = lower ..< out.unicodeScalars.index(lower, offsetBy: chip.length)
            let runs = out[range].runs
            guard let first = runs.first,
                  !runs.contains(where: { $0.link != nil || $0.inlinePresentationIntent?.contains(.code) == true }) else { continue }
            var replacement = AttributedString("#" + TextDirection.isolated(chip.title), attributes: first.attributes)
            replacement.link = RoomMentions.link(to: chip.id)
            replacement[RoomReferenceKey.self] = chip.id
            out.replaceSubrange(range, with: replacement)
        }
    }

    /// Each key the catalog has, in runs that are neither code nor a link.
    private static func markKeys(in out: inout AttributedString, _ catalog: EmojiCatalog) {
        var keys: [(offset: Int, length: Int, key: String)] = []
        for run in out.runs where run.link == nil && run.inlinePresentationIntent?.contains(.code) != true {
            let runText = String(out[run.range].characters)
            let start = out.unicodeScalars.distance(from: out.startIndex, to: run.range.lowerBound)
            for range in EmojiKeys.ranges(in: runText, known: { catalog[$0] != nil }) {
                keys.append((start + runText.unicodeScalars.distance(from: runText.startIndex, to: range.lowerBound),
                             runText.unicodeScalars.distance(from: range.lowerBound, to: range.upperBound), String(runText[range])))
            }
        }
        for key in keys {
            let lower = out.unicodeScalars.index(out.startIndex, offsetBy: key.offset)
            out[lower ..< out.unicodeScalars.index(lower, offsetBy: key.length)][CustomEmojiKey.self] = key.key
        }
    }

    /// The distinct code spans and blocks in the text as rendered, in order, such as the token
    /// in a server's `/invite-device` notice, for copying on their own.
    public static func code(_ body: JSONValue?) -> [String] {
        var seen = Set<String>()
        let text = attributed(body)
        return text.runs.compactMap { run in
            guard run.inlinePresentationIntent?.contains(.code) == true else { return nil }
            let code = String(text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
            return code.isEmpty || !seen.insert(code).inserted ? nil : code
        }
    }

    /// The distinct links in the text as rendered, in order.
    public static func links(_ body: JSONValue?) -> [URL] {
        var seen = Set<URL>()
        return attributed(body).runs.compactMap(\.link).filter { seen.insert($0).inserted }
    }

    /// apron-web's `BARE_URL` on unescaped text: from `http(s)://`, or `apron:?` where a scheme
    /// could start, to whitespace, `<`, `>` or `"`.
    private static let bareURL = try! NSRegularExpression(
        pattern: #"(?:\bhttps?://|(?<![A-Za-z0-9_+.-])apron:\?)[^\s<>"]+"#, options: .caseInsensitive)
    private static let complete = try! NSRegularExpression(pattern: #"^(?:https?://[^/?#]|apron:\?.)"#, options: .caseInsensitive)

    /// Bare links in plain text. Trailing punctuation is left out, as is a closing `)` with no
    /// opening one in the link, so "(see https://example.com)." links just the URL.
    static func bareLinks(in text: String) -> [(range: Range<String.Index>, url: URL)] {
        bareURL.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let found = Range(match.range, in: text) else { return nil }
            var candidate = text[found]
            while true {
                let trimmed = candidate.dropLastWhile { ".,:;!?'*_~&".contains($0) }
                let closes = trimmed.count { $0 == ")" }, opens = trimmed.count { $0 == "(" }
                candidate = trimmed.hasSuffix(")") && closes > opens ? trimmed.dropLast() : trimmed
                if candidate == trimmed { break }
            }
            let written = String(candidate)
            guard complete.firstMatch(in: written, range: NSRange(written.startIndex..., in: written)) != nil,
                  let url = URL(string: written) else { return nil }
            return (candidate.startIndex ..< candidate.endIndex, url)
        }
    }

    /// The schemes apron-web's sanitizer lets a link keep, Apron's own included.
    static func linkable(_ url: URL) -> Bool {
        ["http", "https", "ftp", "ftps", "mailto", "tel", "callto", "sms", "cid", "xmpp", "matrix", "apron"]
            .contains(url.scheme?.lowercased() ?? "")
    }
}

private extension Substring {
    func dropLastWhile(_ predicate: (Character) -> Bool) -> Substring {
        var end = endIndex
        while end > startIndex, predicate(self[index(before: end)]) { end = index(before: end) }
        return self[startIndex ..< end]
    }
}

/// Marks a custom emoji's key in rendered text (`MessageText`); the value is the key.
public enum CustomEmojiKey: AttributedStringKey {
    public typealias Value = String
    public static let name = "ApronCustomEmojiKey"
}
