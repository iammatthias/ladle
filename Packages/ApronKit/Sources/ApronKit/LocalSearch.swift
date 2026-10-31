import Foundation

/// A query: the text to find, and its filters, each folded (`LocalSearch.folded`). `user:@ada` (or
/// `user:ada`, or `user:"Ada Lovelace"` by name) keeps what someone sent; `room:#general` (or
/// `room:general`, or a room's title) keeps what is in a room and its threads. Several of one
/// filter keep what matches any of them.
public struct SearchQuery: Hashable, Sendable {
    /// What a message's text must hold, as one run; empty with only filters.
    public var text: String
    public var users: [String]
    public var rooms: [String]

    public init(text: String, users: [String], rooms: [String]) {
        self.text = text
        self.users = users
        self.rooms = rooms
    }

    /// Asks for nothing: no words and no filters.
    public var isEmpty: Bool { text.isEmpty && users.isEmpty && rooms.isEmpty }
}

/// What a search resolves its filters by: the users it has met, the rooms shown, and the room a
/// thread that isn't shown is in, from its kept record (`parent_room_id`, §3.4).
public struct SearchContext {
    public struct Room: Hashable, Sendable {
        public var id: String
        public var title: String
        public var parentRoomID: String?

        public init(id: String, title: String, parentRoomID: String? = nil) {
            self.id = id
            self.title = title
            self.parentRoomID = parentRoomID
        }
    }

    public var users: [UserObject]
    public var rooms: [Room]
    public var parentOf: (String) -> String?

    public init(users: [UserObject], rooms: [Room], parentOf: @escaping (String) -> String? = { _ in nil }) {
        self.users = users
        self.rooms = rooms
        self.parentOf = parentOf
    }
}

/// A run of a snippet's text, and whether it is what was searched for.
public struct SnippetPart: Hashable, Sendable {
    public var text: String
    public var match: Bool

    public init(_ text: String, match: Bool) {
        self.text = text
        self.match = match
    }
}

/// A `user:` or `room:` value being typed at the caret. `start` and `end` are UTF-16 offsets into
/// the query, as `UITextField`'s selection counts them: where the value starts, after `user:` or
/// `room:`, and where it ends, at the next space or the end.
public struct FilterAtCaret: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case users, rooms }

    public var kind: Kind
    public var start: Int
    public var end: Int
    /// What is typed of it before the caret, without its `@` or `#`.
    public var typed: String
}

/// Searching the messages on this device by the text of a query, as apron-web's `search.ts`
/// (#137, #166). A message matches when its text holds what was typed, in any case, with or
/// without accents, any run of spaces as one; `user:` and `room:` narrow it (`parse`). Results go
/// newest first.
///
/// Offsets and substring tests work in UTF-16 code units, as the web's string indices do, so
/// `snippet` cuts and `filterAtCaret` positions come out the same as apron-web's. Spaces are
/// JavaScript's `\s` set, which is neither `Character.isWhitespace` nor ICU's `\s`.
public enum LocalSearch {
    /// The most results a search shows: past them, a narrower query finds the rest.
    public static let limit = 100

    /// Text as a search compares it: lowercase, without accents (`é` is `e`). ASCII, as most
    /// messages are, only has its case folded, skipping the cost of normalizing.
    public static func folded(_ text: String) -> String {
        if text.utf8.allSatisfy({ $0 < 0x80 }) { return text.lowercased() }
        var bare = String.UnicodeScalarView()
        bare.append(contentsOf: text.decomposedStringWithCanonicalMapping.unicodeScalars.filter { !isMark($0) })
        // Foundation's lowercasing, unlike the standard library's, gives a word-final Σ as ς, as JavaScript does.
        return String(bare).lowercased(with: nil)
    }

    /// Reads a query: its `user:` and `room:` filters, and the rest as the text to find, quotes
    /// around all of it dropped. Anything else with a colon, such as a time like 14:30, is text.
    public static func parse(_ query: String) -> SearchQuery {
        var parsed = SearchQuery(text: "", users: [], rooms: [])
        let ns = query as NSString
        var rest = ""
        var at = 0
        for found in filter.matches(in: query, range: NSRange(location: 0, length: ns.length)) {
            rest += ns.substring(with: NSRange(location: at, length: found.range.location - at)) + ns.substring(with: found.range(at: 1)) + " "
            at = NSMaxRange(found.range)
            let isUser = ns.substring(with: found.range(at: 2)).lowercased() == "user"
            let written = [found.range(at: 3), found.range(at: 4)].first { $0.location != NSNotFound }.map(ns.substring) ?? ""
            var value = Array(folded(trimmed(written)).utf16)
            if value.first == (isUser ? 0x40 : 0x23) { value.removeFirst() }
            let text = String(decoding: value, as: UTF16.self)
            if isUser, !text.isEmpty, !parsed.users.contains(text) { parsed.users.append(text) }
            if !isUser, !text.isEmpty, !parsed.rooms.contains(text) { parsed.rooms.append(text) }
        }
        rest += ns.substring(from: at)
        let text = oneLine(folded(rest))
        let quoted = text.count >= 2 && text.first == 0x22 && text.last == 0x22 && !text.dropFirst().dropLast().contains(0x22)
        parsed.text = quoted ? trimmed(String(decoding: text.dropFirst().dropLast(), as: UTF16.self)) : String(decoding: text, as: UTF16.self)
        return parsed
    }

    /// Whether a message matches `query`, or nil for a query that asks for nothing. A filter's
    /// value is an id or a name, resolved against `context`; one that names no one known still
    /// matches a sender's or room's own id, and a sender's name as the message carries it.
    public static func matcher(_ query: SearchQuery, in context: SearchContext) -> ((MessageSnapshot) -> Bool)? {
        guard !query.isEmpty else { return nil }
        func named(_ user: UserObject) -> Bool {
            query.users.contains(folded(user.userID)) || name(of: user).map { query.users.contains(folded($0)) } == true
        }
        let userIDs = Set(context.users.filter(named).map(\.userID))
        var roomIDs = Set(context.rooms.filter { query.rooms.contains(folded($0.id)) || query.rooms.contains(folded($0.title)) }.map(\.id))
        // One pass in order, as the web's: a thread joins when its parent was named or joined before it.
        for room in context.rooms where room.parentRoomID.map(roomIDs.contains) == true { roomIDs.insert(room.id) }
        func inRoom(_ roomID: String) -> Bool { roomIDs.contains(roomID) || query.rooms.contains(folded(roomID)) }
        let parentOf = context.parentOf
        return { message in
            if message.isTombstone { return false }
            if !query.users.isEmpty, !userIDs.contains(message.from.userID), !named(message.from) { return false }
            if !query.rooms.isEmpty, !inRoom(message.roomID), parentOf(message.roomID).map(inRoom) != true { return false }
            return query.text.isEmpty || matchesText(message, query.text)
        }
    }

    /// Whether `message` has text holding `text` (as `parse` makes it); a deleted message has none.
    public static func matchesText(_ message: MessageSnapshot, _ text: String) -> Bool {
        guard !text.isEmpty, !message.isTombstone, let body = message.body?["text"]?.stringValue else { return false }
        return oneLine(folded(body)).firstRange(of: text.utf16) != nil
    }

    /// The newest `limit` of the messages that match, each once (its latest snapshot by `log_id`),
    /// from any number of sources, newest posted first; `more` when others matched too.
    public static func newestMatches(_ sources: [[MessageSnapshot]], limit: Int = LocalSearch.limit) -> (messages: [MessageSnapshot], more: Bool) {
        var latest: [LogID: MessageSnapshot] = [:]
        for source in sources {
            for message in source where latest[message.messageID].map({ message.logID > $0.logID }) ?? true {
                latest[message.messageID] = message
            }
        }
        let messages = latest.values.sorted { $0.messageID > $1.messageID }
        return (Array(messages.prefix(limit)), messages.count > limit)
    }

    /// About `width` UTF-16 units of `text` from a little before where it first holds `found` (as
    /// `parse` makes it), on one line, with each place it does marked: "…the deploy failed at 4pm…".
    public static func snippet(_ text: String, found: String, width: Int = 140) -> [SnippetPart] {
        let line = oneLine(text)
        // Where each unit of the folded text came from, so a match found there marks the text as written.
        var fold: [UInt16] = []
        var from: [Int] = []
        var offset = 0
        for scalar in String(decoding: line, as: UTF16.self).unicodeScalars {
            for unit in folded(String(scalar)).utf16 {
                fold.append(unit)
                from.append(offset)
            }
            offset += scalar.utf16.count
        }
        let needle = Array(found.utf16)
        var ranges: [(from: Int, to: Int)] = []
        var next = needle.isEmpty ? nil : fold.firstRange(of: needle)?.lowerBound
        while let at = next {
            let end = at + needle.count
            ranges.append((from[at], end < from.count ? from[end] : line.count))
            next = fold[end...].firstRange(of: needle)?.lowerBound
        }
        let first = ranges.first?.from ?? 0
        // A little before it, so the match shows even where only two narrow lines of it do.
        var start = max(0, first - min(30, width / 3))
        var end = min(line.count, start + width)
        start = max(0, end - width)
        // Whole words at the ends, where it was cut.
        if start > 0, let space = line[start...].firstIndex(of: 0x20), space < first { start = space + 1 }
        if end < line.count, let space = line[...end].lastIndex(of: 0x20), space > start { end = space }

        var parts: [SnippetPart] = []
        func push(_ from: Int, _ to: Int, match: Bool) {
            guard from < to else { return }
            push(String(decoding: line[from ..< to], as: UTF16.self), match: match)
        }
        func push(_ text: String, match: Bool) {
            if parts.last?.match == match { parts[parts.count - 1].text += text } else { parts.append(SnippetPart(text, match: match)) }
        }
        if start > 0 { push("…", match: false) }
        var at = start
        for range in ranges where range.to > at && range.from < end {
            push(at, max(at, range.from), match: false)
            push(max(at, range.from), min(range.to, end), match: true)
            at = min(range.to, end)
        }
        push(at, end, match: false)
        if end < line.count { push("…", match: false) }
        return parts
    }

    /// The `user:` or `room:` value the caret is in, for suggesting one, or nil anywhere else.
    /// `caret` is a UTF-16 offset, as `UITextField`'s selection counts it.
    public static func filterAtCaret(_ query: String, caret: Int) -> FilterAtCaret? {
        let units = Array(query.utf16)
        let caret = min(max(caret, 0), units.count)
        let ns = query as NSString
        guard let found = typingFilter.firstMatch(in: query, range: NSRange(location: 0, length: caret)) else { return nil }
        var end = caret
        while end < units.count, !isSpace(units[end]) { end += 1 }
        let kind: FilterAtCaret.Kind = ns.substring(with: found.range(at: 1)).lowercased() == "user" ? .users : .rooms
        return FilterAtCaret(kind: kind, start: caret - found.range(at: 2).length - found.range(at: 3).length, end: end, typed: ns.substring(with: found.range(at: 3)))
    }

    /// `query` with the filter value `at` replaced by `value` and a space after it, and the caret
    /// (a UTF-16 offset) after that space, ready for the next word.
    public static func withFilterValue(_ query: String, at: FilterAtCaret, value: String) -> (query: String, caret: Int) {
        let units = Array(query.utf16)
        var rest = Array(units[min(at.end, units.count)...])
        if rest.first != 0x20 { rest.insert(0x20, at: 0) }
        let written = units[..<min(at.start, units.count)] + value.utf16 + rest
        return (String(decoding: written, as: UTF16.self), at.start + value.utf16.count + 1)
    }

    /// Of `people`, those whose name or id starts with `typed` (any case, with or without
    /// accents), one it names exactly first, then those holding it, at most `limit`; within a rank
    /// by name, else id. That order is the web's `localeCompare` at base sensitivity: a localized
    /// comparison ignoring case and accents, where `localizedStandardCompare` would also order
    /// digits by value ("a9" before "a10") and set accents apart. Ties keep `people`'s order.
    public static func searchPeople<Person>(_ people: [Person], typed: String, limit: Int = 8, id: (Person) -> String, name: (Person) -> String?) -> [Person] {
        let wanted = folded(trimmed(typed))
        func rank(_ person: Person) -> Int? {
            if wanted.isEmpty { return 1 }
            let keys = [folded(trimmed(name(person) ?? "")), folded(id(person))]
            if keys.contains(wanted) { return 0 }
            if keys.contains(where: { $0.utf16.starts(with: wanted.utf16) }) { return 1 }
            if keys.contains(where: { $0.utf16.firstRange(of: wanted.utf16) != nil }) { return 2 }
            return nil
        }
        let ranked = people.compactMap { person in rank(person).map { (person: person, rank: $0, key: name(person) ?? id(person)) } }
        return ranked.sorted { a, b in
            a.rank != b.rank ? a.rank < b.rank : a.key.compare(b.key, options: [.caseInsensitive, .diacriticInsensitive], range: nil, locale: .current) == .orderedAscending
        }.prefix(limit).map(\.person)
    }

    private static func name(of user: UserObject) -> String? { user.json["name"]?.stringValue }

    private static func isMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: true
        default: false
        }
    }

    /// JavaScript's `\s` (and `trim`): all in the Basic Multilingual Plane, so one UTF-16 unit each.
    private static func isSpace(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x09 ... 0x0D, 0x20, 0xA0, 0x1680, 0x2000 ... 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: true
        default: false
        }
    }

    /// `isSpace` as a regex class body.
    private static let space = #"\t\n\x{0B}\f\r \x{A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}"#

    // The keywords spell out each letter's two cases: ICU's case-insensitive matching folds `ſ` to
    // `s`, which JavaScript's `/i` without `u` does not.
    private static let keyword = "([uU][sS][eE][rR]|[rR][oO][oO][mM])"

    /// A filter: `user:` or `room:` after a space or at the start, and its value, `"quoted"` (the
    /// closing quote optional) or up to the next space.
    private static let filter = try! NSRegularExpression(pattern: #"(^|[\#(space)])\#(keyword):(?:"([^"]*)"?|([^\#(space)]*))"#)

    // `\z`, not `$`: ICU's `$` also matches before a final line break, JavaScript's does not.
    private static let typingFilter = try! NSRegularExpression(pattern: #"(?:^|[\#(space)])\#(keyword):([@#]?)([^\#(space)"]*)\z"#)

    private static func trimmed(_ text: String) -> String {
        let units = Array(text.utf16)
        guard let first = units.firstIndex(where: { !isSpace($0) }), let last = units.lastIndex(where: { !isSpace($0) }) else { return "" }
        return String(decoding: units[first ... last], as: UTF16.self)
    }

    /// `text` with each run of spaces one space, trimmed.
    private static func oneLine(_ text: String) -> [UInt16] {
        var line: [UInt16] = []
        var spaced = false
        for unit in text.utf16 {
            if isSpace(unit) {
                spaced = !line.isEmpty
            } else {
                if spaced { line.append(0x20) }
                spaced = false
                line.append(unit)
            }
        }
        return line
    }
}
