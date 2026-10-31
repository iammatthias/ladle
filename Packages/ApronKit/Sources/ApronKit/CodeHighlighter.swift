import Foundation
import Synchronization

/// What a highlighted run of code is, grouped as apron-web's apron.css colours highlight.js's
/// classes: `comment` (comment, quote), `meta`, `keyword` (keyword, selector-tag, doctag),
/// `string` (string, regexp, symbol), `number` (number, literal, bullet), `title` (title,
/// section, selector-id, selector-class), `type` (built_in, type, a class's title), `attr`
/// (attr, attribute, property, variable, template-variable, name), `addition`, `deletion`,
/// `emphasis` and `strong`.
public enum CodeToken: String, Hashable, Sendable {
    case comment, meta, keyword, string, number, title, type, attr, addition, deletion, emphasis, strong
}

/// The token a run of a highlighted code block is (`CodeHighlighter.highlighted`).
public enum CodeTokenKey: AttributedStringKey {
    public typealias Value = CodeToken
    public static let name = "ApronKit.CodeToken"
}

/// apron-web's `highlight.ts` (#16) without highlight.js: a fenced block whose language is one of
/// its 32, or one of their aliases, is marked with `CodeTokenKey` by a small scanner per language
/// (comments, strings, numbers, keywords, and diff's added and removed lines). A block with no
/// language, an unknown one, or over 20,000 characters stays plain, as on the web, which does
/// not guess a language.
public enum CodeHighlighter {
    /// Longer blocks stay plain, as the web's `MAX_LENGTH`.
    public static let maxLength = 20_000

    public static let languages: Set<String> = [
        "bash", "c", "cpp", "csharp", "css", "diff", "dockerfile", "elixir", "go", "graphql", "haskell", "ini",
        "java", "javascript", "json", "kotlin", "lua", "makefile", "markdown", "nix", "php", "protobuf", "python",
        "ruby", "rust", "scss", "shell", "sql", "swift", "typescript", "xml", "yaml",
    ]

    /// The web's `ALIASES`. `shell` is a prompt-and-output session; `sh` is a script.
    static let aliases: [String: String] = [
        "js": "javascript", "jsx": "javascript", "mjs": "javascript", "cjs": "javascript", "node": "javascript",
        "ts": "typescript", "tsx": "typescript", "mts": "typescript",
        "sh": "bash", "zsh": "bash", "console": "shell", "shell-session": "shell",
        "py": "python", "python3": "python", "rb": "ruby", "rs": "rust", "golang": "go",
        "h": "c", "c++": "cpp", "cc": "cpp", "hpp": "cpp", "cs": "csharp", "c#": "csharp", "kt": "kotlin",
        "html": "xml", "svg": "xml", "svelte": "xml", "vue": "xml",
        "yml": "yaml", "toml": "ini", "jsonc": "json", "json5": "json",
        "md": "markdown", "patch": "diff", "docker": "dockerfile", "make": "makefile", "mk": "makefile",
        "gql": "graphql", "proto": "protobuf", "ex": "elixir", "exs": "elixir", "hs": "haskell",
        "postgres": "sql", "postgresql": "sql", "mysql": "sql", "sqlite": "sql",
    ]

    /// The language a fence names, if it is one that is highlighted.
    public static func language(of fence: String) -> String? {
        let name = fence.lowercased()
        let resolved = aliases[name] ?? name
        return languages.contains(resolved) ? resolved : nil
    }

    /// The block's text with each token's run marked, or nil where it stays plain.
    public static func highlighted(_ source: String, fence: String?) -> AttributedString? {
        guard let language = fence.flatMap(language(of:)), source.count <= maxLength else { return nil }
        let key = "\(language)\n\(source)"
        if let kept = cache.withLock({ $0.blocks[key] }) { return kept }
        let scalars = Array(source.unicodeScalars)
        var out = AttributedString()
        var position = 0
        func piece(_ range: Range<Int>) -> String {
            var text = String.UnicodeScalarView()
            text.append(contentsOf: scalars[range])
            return String(text)
        }
        for span in spans(scalars, language: language) {
            if span.range.lowerBound > position { out += AttributedString(piece(position ..< span.range.lowerBound)) }
            var marked = AttributedString(piece(span.range))
            marked[CodeTokenKey.self] = span.token
            out += marked
            position = span.range.upperBound
        }
        if position < scalars.count { out += AttributedString(piece(position ..< scalars.count)) }
        cache.withLock { kept in
            if kept.order.count >= 500 { kept.blocks[kept.order.removeFirst()] = nil }
            kept.order.append(key)
            kept.blocks[key] = out
        }
        return out
    }

    /// Highlighted blocks kept for reuse, oldest first, as the web keeps 500.
    private static let cache = Mutex<(blocks: [String: AttributedString], order: [String])>(([:], []))

    static func spans(_ source: [Unicode.Scalar], language: String) -> [CodeSpan] {
        var scanner = CodeScanner(source)
        switch language {
        case "diff": scanner.diff()
        case "shell": scanner.shellSession()
        case "markdown": scanner.markdown()
        case "xml": scanner.xml()
        case "css", "scss": scanner.css(scss: language == "scss")
        default: scanner.scan(Grammar.all[language] ?? Grammar(), in: 0 ..< source.count)
        }
        return scanner.spans
    }
}

struct CodeSpan: Equatable {
    var range: Range<Int>
    var token: CodeToken
}

/// What a language's text is made of, for the shared scanner.
struct Grammar {
    struct Quote {
        var open: String
        var close: String
        var escapes = true
        var multiline = false
    }

    enum Keys {
        case none
        /// JSON: a string before a `:` is a key.
        case quoted
        /// YAML, INI and TOML: a bare or quoted name at a line's start before this separator.
        case bare(Unicode.Scalar)
    }

    var lineComments: [String] = []
    var blockComments: [(open: String, close: String)] = []
    var nestedComments = false
    /// Shell-like: a line comment starts only at a line's start or after white space.
    var commentNeedsSpace = false
    var quotes: [Quote] = []
    /// Python's `f"…"`, Rust's `b"…"`: a word that is part of the string after it.
    var stringPrefixes: Set<String> = []
    /// `'a'` is a character, `'a` (a lifetime) and `x'` (a prime) are not.
    var characters = false
    var keywords: Set<String> = []
    var types: Set<String> = []
    var literals: Set<String> = []
    var caseInsensitive = false
    /// The word after one of these is a function's name.
    var titleAfter: Set<String> = []
    /// The word after one of these is a type's name.
    var typeAfter: Set<String> = []
    /// Keywords count only as a line's first word (Dockerfile's instructions).
    var keywordsLeadLines = false
    /// `$name`, `${…}`, `$(NAME)`, `@ivar`: variables.
    var variableSigils: Set<Unicode.Scalar> = []
    /// `@decorator`, `#if`: meta.
    var metaSigils: Set<Unicode.Scalar> = []
    /// Words that are meta wherever they stand (`<?php`).
    var metaWords: [String] = []
    /// `#include` at a line's start: meta.
    var preprocessor = false
    /// Ruby's and Elixir's `:atom`.
    var symbols = false
    /// Rust's `name!`: a macro.
    var macros = false
    var identifierExtra: Set<Unicode.Scalar> = []
    var keys: Keys = .none
    /// INI's `[section]`.
    var sections = false
    /// Makefile's `target:` at a line's start.
    var targets = false
    /// YAML's `- ` list markers and `---` document lines.
    var yamlMarkers = false

    static func words(_ list: String) -> Set<String> { Set(list.split(separator: " ").map(String.init)) }
}

struct CodeScanner {
    let source: [Unicode.Scalar]
    var spans: [CodeSpan] = []
    var index = 0

    init(_ source: [Unicode.Scalar]) { self.source = source }

    var end: Int { source.count }

    func at(_ text: String, _ position: Int? = nil) -> Bool {
        var offset = position ?? index
        for scalar in text.unicodeScalars {
            guard offset < end, source[offset] == scalar else { return false }
            offset += 1
        }
        return true
    }

    func scalar(_ offset: Int) -> Unicode.Scalar? { offset >= 0 && offset < end ? source[offset] : nil }

    mutating func mark(_ start: Int, _ token: CodeToken) {
        guard index > start else { return }
        if let last = spans.last, last.token == token, last.range.upperBound == start {
            spans[spans.count - 1].range = last.range.lowerBound ..< index
        } else {
            spans.append(CodeSpan(range: start ..< index, token: token))
        }
    }

    func lineEnd(from offset: Int) -> Int {
        var offset = offset
        while offset < end, source[offset] != "\n" { offset += 1 }
        return offset
    }

    static func isSpace(_ scalar: Unicode.Scalar?) -> Bool { scalar == " " || scalar == "\t" }
    static func isDigit(_ scalar: Unicode.Scalar?) -> Bool { scalar.map { ("0" ... "9").contains($0) } ?? false }
    static func isIdentifierStart(_ scalar: Unicode.Scalar?) -> Bool {
        guard let scalar else { return false }
        return scalar == "_" || scalar.properties.isAlphabetic
    }

    func isIdentifier(_ scalar: Unicode.Scalar?, _ grammar: Grammar) -> Bool {
        guard let scalar else { return false }
        return Self.isIdentifierStart(scalar) || Self.isDigit(scalar) || grammar.identifierExtra.contains(scalar)
    }

    // MARK: The shared scanner

    mutating func scan(_ grammar: Grammar, in range: Range<Int>) {
        index = range.lowerBound
        var lineBlank = true
        var pendingTitle: CodeToken?
        while index < range.upperBound {
            let start = index
            let current = source[index]
            if current == "\n" {
                index += 1
                lineBlank = true
                continue
            }
            if Self.isSpace(current) {
                index += 1
                continue
            }
            defer { lineBlank = false }
            if lineBlank, lineStart(grammar, limit: range.upperBound) { continue }
            if let word = grammar.metaWords.first(where: { at($0) }) {
                index += word.unicodeScalars.count
                mark(start, .meta)
                continue
            }
            if let comment = grammar.blockComments.first(where: { at($0.open) }) {
                blockComment(comment, nested: grammar.nestedComments, limit: range.upperBound)
                continue
            }
            if grammar.lineComments.contains(where: { at($0) }), !grammar.commentNeedsSpace || index == range.lowerBound || Self.isSpace(scalar(index - 1)) || scalar(index - 1) == "\n" {
                index = min(lineEnd(from: index), range.upperBound)
                mark(start, .comment)
                continue
            }
            if let quote = grammar.quotes.first(where: { at($0.open) }) {
                string(quote, limit: range.upperBound)
                keyCheck(grammar, start: start)
                continue
            }
            if grammar.characters, current == "'", character(limit: range.upperBound) {
                mark(start, .string)
                continue
            }
            if Self.isDigit(current) || (current == "." && Self.isDigit(scalar(index + 1)) && !isIdentifier(scalar(index - 1), grammar)) {
                number()
                mark(start, .number)
                continue
            }
            if grammar.variableSigils.contains(current), variable(grammar) {
                mark(start, .attr)
                continue
            }
            if grammar.metaSigils.contains(current), Self.isIdentifierStart(scalar(index + 1)) {
                index += 1
                while isIdentifier(scalar(index), grammar) { index += 1 }
                mark(start, .meta)
                continue
            }
            if grammar.symbols, current == ":", Self.isIdentifierStart(scalar(index + 1)), scalar(index - 1) != ":", !isIdentifier(scalar(index - 1), grammar) {
                index += 1
                while isIdentifier(scalar(index), grammar) { index += 1 }
                mark(start, .string)
                continue
            }
            if Self.isIdentifierStart(current) {
                while index < range.upperBound, isIdentifier(source[index], grammar) { index += 1 }
                var word = String(String.UnicodeScalarView(source[start ..< index]))
                if grammar.stringPrefixes.contains(word.lowercased()), let quote = grammar.quotes.first(where: { at($0.open) }) {
                    string(quote, limit: range.upperBound)
                    mark(start, .string)
                    continue
                }
                if grammar.caseInsensitive { word = word.lowercased() }
                let leads = !grammar.keywordsLeadLines || lineBlank
                if grammar.keywords.contains(word), leads {
                    mark(start, .keyword)
                    pendingTitle = grammar.titleAfter.contains(word) ? .title : grammar.typeAfter.contains(word) ? .type : nil
                    continue
                }
                if grammar.literals.contains(word) {
                    mark(start, .number)
                } else if let title = pendingTitle {
                    mark(start, title)
                } else if grammar.macros, scalar(index) == "!" {
                    index += 1
                    mark(start, .type)
                } else if grammar.types.contains(word) {
                    mark(start, .type)
                }
                pendingTitle = nil
                continue
            }
            pendingTitle = nil
            index += 1
        }
    }

    /// The rules that hold only at a line's first non-blank character; true when one took text.
    private mutating func lineStart(_ grammar: Grammar, limit: Int) -> Bool {
        let start = index
        if grammar.preprocessor, source[index] == "#" {
            index += 1
            while Self.isSpace(scalar(index)) { index += 1 }
            while Self.isIdentifierStart(scalar(index)) { index += 1 }
            mark(start, .meta)
            return true
        }
        if grammar.yamlMarkers {
            if at("---") || at("...") {
                index += 3
                mark(start, .meta)
                return true
            }
            if source[index] == "-", Self.isSpace(scalar(index + 1)) || scalar(index + 1) == "\n" {
                index += 1
                mark(start, .number)
                while Self.isSpace(scalar(index)) { index += 1 }
                if index < limit, source[index] != "\n" { _ = bareKey(grammar, limit: limit) }
                return true
            }
        }
        if grammar.sections, source[index] == "[" {
            let close = lineEnd(from: index)
            if let bracket = source[index ..< close].lastIndex(of: "]") {
                index = bracket + 1
                mark(start, .title)
                return true
            }
        }
        if grammar.targets, source[index] != "#", source[index] != "\t", scalar(index - 1) == "\n" || index == 0 {
            let line = lineEnd(from: index)
            if let colon = source[index ..< line].firstIndex(of: ":"), scalar(colon + 1) != "=",
               !source[index ..< colon].contains(where: { $0 == "=" || $0 == "$" }) {
                index = colon
                mark(start, .title)
                return true
            }
        }
        return bareKey(grammar, limit: limit)
    }

    private mutating func bareKey(_ grammar: Grammar, limit: Int) -> Bool {
        let start = index
        if case .bare(let separator) = grammar.keys {
            var offset = index
            if source[offset] == "\"" || source[offset] == "'" {
                let quote = source[offset]
                offset += 1
                while offset < limit, source[offset] != quote, source[offset] != "\n" { offset += 1 }
                if offset < limit, source[offset] == quote { offset += 1 }
            } else {
                while offset < limit, isIdentifier(source[offset], grammar) || "-.".unicodeScalars.contains(source[offset]) || (source[offset] == " " && separator == ":") {
                    offset += 1
                }
            }
            var after = offset
            while Self.isSpace(scalar(after)) { after += 1 }
            if offset > index, scalar(after) == separator, separator != ":" || Self.isSpace(scalar(after + 1)) || scalar(after + 1) == "\n" || after + 1 == end {
                index = offset
                while index > start, Self.isSpace(source[index - 1]) { index -= 1 }
                mark(start, .attr)
                return true
            }
        }
        return false
    }

    private mutating func keyCheck(_ grammar: Grammar, start: Int) {
        guard case .quoted = grammar.keys else { return mark(start, .string) }
        var after = index
        while Self.isSpace(scalar(after)) || scalar(after) == "\n" { after += 1 }
        mark(start, scalar(after) == ":" ? .attr : .string)
    }

    /// Through the comment's close, or to the end when it never closes.
    private mutating func blockComment(_ comment: (open: String, close: String), nested: Bool, limit: Int) {
        let start = index
        index += comment.open.unicodeScalars.count
        var depth = 1
        while index < limit {
            if at(comment.close) {
                index += comment.close.unicodeScalars.count
                depth -= 1
                if depth == 0 || !nested { break }
            } else if nested, at(comment.open) {
                index += comment.open.unicodeScalars.count
                depth += 1
            } else {
                index += 1
            }
        }
        index = min(index, limit)
        mark(start, .comment)
    }

    /// Through the closing quote; one that never closes ends at its line (or the end, if it may
    /// span lines).
    mutating func string(_ quote: Grammar.Quote, limit: Int) {
        index += quote.open.unicodeScalars.count
        while index < limit {
            if quote.escapes, source[index] == "\\" {
                index += 2
                continue
            }
            if at(quote.close) {
                index += quote.close.unicodeScalars.count
                return
            }
            if !quote.multiline, source[index] == "\n" { return }
            index += 1
        }
        index = min(index, limit)
    }

    private mutating func character(limit: Int) -> Bool {
        if scalar(index + 1) == "\\" {
            var offset = index + 2
            while offset < min(limit, index + 12), source[offset] != "'", source[offset] != "\n" { offset += 1 }
            guard scalar(offset) == "'" else { return false }
            index = offset + 1
            return true
        }
        guard scalar(index + 2) == "'", scalar(index + 1) != "\n" else { return false }
        index += 3
        return true
    }

    /// Decimal, hex, octal and binary numbers, with `_` separators, a fraction, an exponent, and a
    /// suffix (`u32`, `f`, `px`, `%`).
    mutating func number() {
        if source[index] == "0", let base = scalar(index + 1), "xXbBoO".unicodeScalars.contains(base) {
            index += 2
            while let next = scalar(index), next.properties.isASCIIHexDigit || next == "_" { index += 1 }
        } else {
            while Self.isDigit(scalar(index)) || scalar(index) == "_" { index += 1 }
            if scalar(index) == ".", Self.isDigit(scalar(index + 1)) {
                index += 1
                while Self.isDigit(scalar(index)) || scalar(index) == "_" { index += 1 }
            }
            if scalar(index) == "e" || scalar(index) == "E",
               Self.isDigit(scalar(index + 1)) || ((scalar(index + 1) == "+" || scalar(index + 1) == "-") && Self.isDigit(scalar(index + 2))) {
                index += 2
                while Self.isDigit(scalar(index)) { index += 1 }
            }
        }
        while let next = scalar(index), next.properties.isAlphabetic || Self.isDigit(next) || next == "%" { index += 1 }
    }

    /// `$name`, `$1`, `$@`, `${…}`, `$(NAME)` (not `$(command args)`), `@ivar`, `@@cvar`.
    private mutating func variable(_ grammar: Grammar) -> Bool {
        let sigil = source[index]
        var offset = index + 1
        if scalar(offset) == sigil { offset += 1 }
        if scalar(offset) == "{" {
            let line = lineEnd(from: offset)
            guard let close = source[offset ..< line].firstIndex(of: "}") else { return false }
            index = close + 1
            return true
        }
        if scalar(offset) == "(" {
            var inner = offset + 1
            while isIdentifier(scalar(inner), grammar) { inner += 1 }
            guard inner > offset + 1, scalar(inner) == ")" else { return false }
            index = inner + 1
            return true
        }
        if Self.isIdentifierStart(scalar(offset)) {
            while isIdentifier(scalar(offset), grammar) && scalar(offset) != "'" { offset += 1 }
            index = offset
            return true
        }
        if sigil == "$", let special = scalar(offset), "@*#?$!0123456789-<^".unicodeScalars.contains(special) {
            index = offset + 1
            return true
        }
        return false
    }

    // MARK: Line-shaped languages

    /// highlight.js's diff: headers as comments and hunks as meta before `+` and `-` lines.
    mutating func diff() {
        while index < end {
            let start = index
            let line = lineEnd(from: index)
            let token: CodeToken? =
                at("@@") || (at("*** ") && source[start ..< line].last == "*") || (at("--- ") && source[start ..< line].last == "-") ? .meta
                : ["Index: ", "index ", "===", "---", "+++", "*** ", "diff --git"].contains(where: { at($0) }) ? .comment
                : at("+") || at(">") || at("!") ? .addition
                : at("-") || at("<") ? .deletion
                : nil
            index = line
            if let token { mark(start, token) }
            index += 1
        }
    }

    /// highlight.js's shell: a prompt (`$ `, `user@host:~$ `, `> `) as meta and the command after
    /// it as Bash; other lines are output.
    mutating func shellSession() {
        let bash = Grammar.all["bash"]!
        var lineStart = 0
        while lineStart < end {
            let line = lineEnd(from: lineStart)
            index = lineStart
            var spaces = 0
            while spaces < 3, Self.isSpace(scalar(index)) {
                index += 1
                spaces += 1
            }
            let promptStart = index
            while let next = scalar(index), index < line, next.properties.isAlphabetic || Self.isDigit(next) || "/~_[]()@-:.".unicodeScalars.contains(next) { index += 1 }
            if let sign = scalar(index), index < line, ">%$#".unicodeScalars.contains(sign) {
                index += 1
                if scalar(index) == " " { index += 1 }
                mark(promptStart, .meta)
                scan(bash, in: index ..< line)
            }
            lineStart = line + 1
        }
    }

    mutating func markdown() {
        var inFence = false
        while index < end {
            let start = index
            let line = lineEnd(from: index)
            while Self.isSpace(scalar(index)) { index += 1 }
            if at("```") || at("~~~") {
                inFence.toggle()
                index = line
            } else if inFence {
                index = line
            } else if at("#") {
                var level = 0
                while scalar(index + level) == "#" { level += 1 }
                if level <= 6, Self.isSpace(scalar(index + level)) || index + level == line {
                    index = line
                    mark(start, .title)
                }
            } else if at(">") {
                index = line
                mark(start, .comment)
            } else {
                let bullet = index
                if let mark = scalar(index), "-*+".unicodeScalars.contains(mark), Self.isSpace(scalar(index + 1)) {
                    index += 1
                } else {
                    while Self.isDigit(scalar(index)) { index += 1 }
                    if index > bullet, scalar(index) == "." || scalar(index) == ")", Self.isSpace(scalar(index + 1)) { index += 1 } else { index = bullet }
                }
                mark(bullet, .number)
                markdownInline(to: line)
            }
            index = line + 1
        }
    }

    private mutating func markdownInline(to line: Int) {
        while index < line {
            let start = index
            if at("**") || at("__"), let close = find(String(String.UnicodeScalarView(source[index ..< index + 2])), from: index + 2, to: line) {
                index = close + 2
                mark(start, .strong)
            } else if at("*") || at("_"), Self.isIdentifierStart(scalar(index + 1)) || scalar(index + 1) == "`",
                      let close = find(String(source[index]), from: index + 1, to: line) {
                index = close + 1
                mark(start, .emphasis)
            } else if at("`"), let close = find("`", from: index + 1, to: line) {
                index = close + 1
            } else if at("["), let close = find("](", from: index + 1, to: line) {
                index = close + 1
                mark(start, .string)
                if let paren = find(")", from: index, to: line) { index = paren + 1 }
            } else {
                index += 1
            }
        }
    }

    private func find(_ text: String, from: Int, to limit: Int) -> Int? {
        var offset = from
        while offset < limit {
            if at(text, offset) { return offset }
            offset += 1
        }
        return nil
    }

    /// HTML and XML: comments, `<!DOCTYPE>` and `<?xml?>` as meta, tag names and attributes, and
    /// attribute values as strings. What is between tags stays plain.
    mutating func xml() {
        while index < end {
            let start = index
            if at("<!--") {
                blockComment(("<!--", "-->"), nested: false, limit: end)
            } else if at("<!") || at("<?") {
                while index < end, source[index] != ">" { index += 1 }
                index = min(index + 1, end)
                mark(start, .meta)
            } else if at("<"), Self.isIdentifierStart(scalar(index + 1)) || (scalar(index + 1) == "/" && Self.isIdentifierStart(scalar(index + 2))) {
                index += scalar(index + 1) == "/" ? 2 : 1
                let name = index
                while let next = scalar(index), !Self.isSpace(next), next != "\n", next != ">", next != "/" { index += 1 }
                mark(name, .attr)
                tagBody()
            } else {
                index += 1
            }
        }
    }

    private mutating func tagBody() {
        while index < end, source[index] != ">" {
            let start = index
            let current = source[index]
            if current == "\"" || current == "'" {
                string(Grammar.Quote(open: String(current), close: String(current), escapes: false, multiline: true), limit: end)
                mark(start, .string)
            } else if Self.isIdentifierStart(current) {
                while let next = scalar(index), Self.isIdentifierStart(next) || Self.isDigit(next) || "-:.".unicodeScalars.contains(next) { index += 1 }
                mark(start, .attr)
            } else {
                index += 1
            }
        }
        index = min(index + 1, end)
    }

    /// CSS and SCSS: comments, at-rules, selectors (tags as keywords, classes and ids as
    /// titles), properties, and values (numbers, colors, strings, `!important`, `$variables`).
    mutating func css(scss: Bool) {
        var inValue = false
        var statementStart = true
        let identifier: (Unicode.Scalar?) -> Bool = { scalar in
            guard let scalar else { return false }
            return Self.isIdentifierStart(scalar) || Self.isDigit(scalar) || scalar == "-"
        }
        while index < end {
            let start = index
            let current = source[index]
            if at("/*") {
                blockComment(("/*", "*/"), nested: false, limit: end)
                continue
            }
            if scss, at("//") {
                index = lineEnd(from: index)
                mark(start, .comment)
                continue
            }
            if current == "\"" || current == "'" {
                string(Grammar.Quote(open: String(current), close: String(current)), limit: end)
                mark(start, .string)
                statementStart = false
                continue
            }
            switch current {
            case "{", ";", "}":
                inValue = false
                statementStart = true
                index += 1
                continue
            case " ", "\t", "\n":
                index += 1
                continue
            default: break
            }
            defer { statementStart = false }
            if current == "@", Self.isIdentifierStart(scalar(index + 1)) {
                index += 1
                while identifier(scalar(index)) { index += 1 }
                mark(start, .keyword)
            } else if current == "$", Self.isIdentifierStart(scalar(index + 1)) {
                index += 1
                while identifier(scalar(index)) { index += 1 }
                mark(start, .attr)
            } else if current == "!", at("!important") {
                index += 10
                mark(start, .keyword)
            } else if inValue, current == "#", scalar(index + 1)?.properties.isASCIIHexDigit == true {
                index += 1
                while scalar(index)?.properties.isASCIIHexDigit == true { index += 1 }
                mark(start, .number)
            } else if Self.isDigit(current) || (current == "." && Self.isDigit(scalar(index + 1))) || (current == "-" && Self.isDigit(scalar(index + 1)) && inValue) {
                if current == "-" { index += 1 }
                number()
                mark(start, .number)
            } else if !inValue, current == "." || current == "#", Self.isIdentifierStart(scalar(index + 1)) || scalar(index + 1) == "-" {
                index += 1
                while identifier(scalar(index)) { index += 1 }
                mark(start, .title)
            } else if !inValue, current == ":" {
                index += 1
                if scalar(index) == ":" { index += 1 }
                while identifier(scalar(index)) { index += 1 }
            } else if Self.isIdentifierStart(current) || current == "-" {
                while identifier(scalar(index)) { index += 1 }
                if !inValue, statementStart, isProperty(from: index) {
                    mark(start, .attr)
                    while Self.isSpace(scalar(index)) { index += 1 }
                    index += 1
                    inValue = true
                } else if !inValue, Self.htmlTags.contains(String(String.UnicodeScalarView(source[start ..< index])).lowercased()) {
                    mark(start, .keyword)
                }
            } else {
                index += 1
            }
        }
    }

    /// A name followed by `:` whose declaration opens no block (`a:hover {` is a selector).
    private func isProperty(from offset: Int) -> Bool {
        var offset = offset
        while Self.isSpace(scalar(offset)) { offset += 1 }
        guard scalar(offset) == ":" else { return false }
        while offset < end, ![";", "}", "\n"].contains(source[offset]) {
            if source[offset] == "{" { return false }
            offset += 1
        }
        return true
    }

    static let htmlTags = Grammar.words("""
    a abbr article aside audio b blockquote body button canvas code dd details dialog div dl dt em fieldset figure footer form \
    h1 h2 h3 h4 h5 h6 header hr html i iframe img input label legend li main nav ol optgroup option p pre section select small \
    span strong summary sup sub svg table tbody td textarea tfoot th thead tr ul video
    """)
}
