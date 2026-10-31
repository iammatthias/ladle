import Foundation

/// A rendered body's blocks, as apron-web's markdown-it renders them (§3.5): paragraphs,
/// headings, quotes, lists, code blocks, rules, GFM tables, and each markdown image on its own,
/// for the app to show under the media gate. Inline text keeps its styles, links and chips; code
/// keeps its text as written. A `plain` body is one paragraph.
public indirect enum MessageBlock: Hashable, Sendable {
    case paragraph(AttributedString)
    case heading(level: Int, AttributedString)
    case quote([MessageBlock])
    /// Each item's number is `start` plus its place; an unordered list has none.
    case list(ordered: Bool, start: Int, items: [[MessageBlock]])
    case code(language: String?, text: String)
    case rule
    case table(MessageTable)
    case image(MessageImage)
}

public struct MessageTable: Hashable, Sendable {
    public enum Alignment: Hashable, Sendable { case leading, center, trailing }
    public var alignments: [Alignment]
    public var header: [AttributedString]
    /// Each row has one cell per column: a short row is padded, as markdown-it does.
    public var rows: [[AttributedString]]
}

/// A markdown image (`![alt](url)`): where it is, and its alt text, empty when none was written.
public struct MessageImage: Hashable, Sendable {
    public var url: URL
    public var alt: String
}

extension MessageBlock {
    /// The blocks as one string, a line per block, for reading its runs (links, code) or for
    /// where blocks cannot show: code as inline code, a table's cells apart, an image as its alt.
    public static func flattened(_ blocks: [MessageBlock]) -> AttributedString {
        var out = AttributedString()
        for (index, block) in blocks.enumerated() {
            if index > 0 { out += AttributedString("\n") }
            switch block {
            case .paragraph(let text), .heading(_, let text): out += text
            case .quote(let inner): out += flattened(inner)
            case .list(_, _, let items): out += flattened(items.map { .quote($0) })
            case .code(_, let text):
                var code = AttributedString(text)
                code.inlinePresentationIntent = .code
                out += code
            case .rule: break
            case .table(let table):
                out += flattened(([table.header] + table.rows).map { cells in
                    .paragraph(cells.reduce(into: AttributedString()) { line, cell in
                        if !line.characters.isEmpty { line += AttributedString(" | ") }
                        line += cell
                    })
                })
            case .image(let image): out += AttributedString(image.alt)
            }
        }
        return out
    }

    /// Each inline text in the blocks, code aside, passed through `transform`.
    func mapText(_ transform: (AttributedString) -> AttributedString) -> MessageBlock {
        switch self {
        case .paragraph(let text): return .paragraph(transform(text))
        case .heading(let level, let text): return .heading(level: level, transform(text))
        case .quote(let inner): return .quote(inner.map { $0.mapText(transform) })
        case .list(let ordered, let start, let items): return .list(ordered: ordered, start: start, items: items.map { $0.map { $0.mapText(transform) } })
        case .table(var table):
            table.header = table.header.map(transform)
            table.rows = table.rows.map { $0.map(transform) }
            return .table(table)
        case .code, .rule, .image: return self
        }
    }
}

/// Splits a parsed body (Foundation's full CommonMark and GFM parse) into blocks by its
/// presentation intents, outermost first.
enum BlockReader {
    private typealias Run = (intents: [PresentationIntent.IntentType], text: AttributedString)

    static func blocks(_ parsed: AttributedString) -> [MessageBlock] {
        let runs: [Run] = parsed.runs.map { run in
            var text = AttributedString(parsed[run.range])
            text.presentationIntent = nil
            return ((run.presentationIntent?.components ?? []).reversed(), text)
        }
        return blocks(runs[...], depth: 0)
    }

    private static func blocks(_ runs: ArraySlice<Run>, depth: Int) -> [MessageBlock] {
        groups(runs, depth: depth).flatMap { group -> [MessageBlock] in
            guard let intent = group.first?.intents[safe: depth] else { return paragraphs(group) }
            switch intent.kind {
            case .header(let level): return [.heading(level: level, joined(group))]
            case .blockQuote: return [.quote(blocks(group, depth: depth + 1))]
            case .orderedList, .unorderedList:
                let items = groups(group, depth: depth + 1).map { blocks($0, depth: depth + 2) }
                var start = 1
                if case .listItem(let ordinal)? = group.first?.intents[safe: depth + 1]?.kind { start = ordinal }
                if case .orderedList = intent.kind { return [.list(ordered: true, start: start, items: items)] }
                return [.list(ordered: false, start: 1, items: items)]
            case .codeBlock(let language):
                var text = String(joined(group).characters)
                if text.hasSuffix("\n") { text.removeLast() }
                return [.code(language: language.flatMap { $0.isEmpty ? nil : $0 }, text: text)]
            case .thematicBreak: return [.rule]
            case .table(let columns): return [.table(table(group, columns: columns, depth: depth))]
            default: return paragraphs(group)
            }
        }
    }

    private static func table(_ runs: ArraySlice<Run>, columns: [PresentationIntent.TableColumn], depth: Int) -> MessageTable {
        var header: [AttributedString] = []
        var rows: [[AttributedString]] = []
        for row in groups(runs, depth: depth + 1) {
            var cells = Array(repeating: AttributedString(), count: columns.count)
            for cell in groups(row, depth: depth + 2) {
                guard case .tableCell(let column)? = cell.first?.intents[safe: depth + 2]?.kind, cells.indices.contains(column) else { continue }
                cells[column] = joined(cell)
            }
            if case .tableHeaderRow? = row.first?.intents[safe: depth + 1]?.kind { header = cells } else { rows.append(cells) }
        }
        let alignments: [MessageTable.Alignment] = columns.map {
            switch $0.alignment {
            case .center: .center
            case .right: .trailing
            default: .leading
            }
        }
        return MessageTable(alignments: alignments, header: header, rows: rows)
    }

    /// A paragraph's text, each image that may be media taken out as a block of its own, the
    /// text around it kept as paragraphs. An image on another scheme keeps its alt text in line.
    private static func paragraphs(_ runs: ArraySlice<Run>) -> [MessageBlock] {
        var out: [MessageBlock] = []
        var text = AttributedString()
        func flush() {
            if !String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.paragraph(trimmed(text))) }
            text = AttributedString()
        }
        for run in runs {
            for piece in run.text.runs {
                let written = AttributedString(run.text[piece.range])
                guard let url = piece.imageURL, ["http", "https", "data"].contains(url.scheme?.lowercased() ?? "") else {
                    var kept = written
                    kept.imageURL = nil
                    text += kept
                    continue
                }
                flush()
                let alt = String(written.characters).replacingOccurrences(of: "\u{FFFC}", with: "")
                out.append(.image(MessageImage(url: url, alt: alt)))
            }
        }
        flush()
        return out
    }

    /// Consecutive runs that share the block at `depth`; runs with no block there each stand alone
    /// together, as a paragraph.
    private static func groups(_ runs: ArraySlice<Run>, depth: Int) -> [ArraySlice<Run>] {
        var out: [ArraySlice<Run>] = []
        var start = runs.startIndex
        for index in runs.indices where index > start {
            if runs[index].intents[safe: depth]?.identity != runs[start].intents[safe: depth]?.identity {
                out.append(runs[start ..< index])
                start = index
            }
        }
        if start < runs.endIndex { out.append(runs[start...]) }
        return out
    }

    private static func joined(_ runs: ArraySlice<Run>) -> AttributedString {
        runs.reduce(into: AttributedString()) { $0 += $1.text }
    }

    /// Without the line breaks a block's edge leaves, such as raw HTML's trailing newline.
    private static func trimmed(_ text: AttributedString) -> AttributedString {
        var out = text
        while let last = out.characters.last, last.isNewline { out.characters.removeLast() }
        while let first = out.characters.first, first.isNewline { out.characters.removeFirst() }
        return out
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
