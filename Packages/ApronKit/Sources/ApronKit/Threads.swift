import Foundation

/// What Start Thread on a message suggests, as apron-web's `threadTitleFor` and
/// `threadDescriptionFor`: the message's first line as the title, and its text quoted as the
/// description. Threads don't point at a message, so the link back is the thread's first reply,
/// which replies to it (`reply_to` crosses rooms, §3.5).
public enum ThreadStart {
    public static let titleLimit = 60
    public static let descriptionLimit = 500

    /// The first line that is not blank, its runs of white space made one space, at most 60 code
    /// points; "Thread" without one.
    public static func title(_ body: JSONValue?) -> String {
        let text = body?["text"]?.stringValue ?? ""
        let line = text.split(separator: "\n", omittingEmptySubsequences: false)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") } ?? ""
        let short = shorten(line, titleLimit)
        return short.isEmpty ? "Thread" : short
    }

    /// The text as a Markdown `>` quote, cut to about 500 code points on a line or word boundary
    /// with a code fence the cut leaves open closed. A plain body is escaped, since a description
    /// is Markdown. Nil for a message without text.
    public static func description(_ body: JSONValue?) -> String? {
        let text = (body?["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let markdown = body?["format"]?.stringValue == "markdown"
        return quote(shortenMarkdown(markdown ? text : escape(text), descriptionLimit))
    }

    /// Every line behind `> `, a blank one behind `>`.
    public static func quote(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? ">" : "> " + $0 }
            .joined(separator: "\n")
    }

    /// Plain text as Markdown that reads the same: each character Markdown could take as syntax
    /// behind a backslash, and a line's leading spaces and tabs as entities.
    public static func escape(_ text: String) -> String {
        let syntax = Set("\\`*_{}[]()#+-.!|>~<=&")
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var escaped = ""
            for character in line { escaped += syntax.contains(character) ? "\\\(character)" : String(character) }
            let indent = escaped.prefix { $0 == " " || $0 == "\t" }
            return indent.map { $0 == " " ? "&#32;" : "&#9;" }.joined() + escaped.dropFirst(indent.count)
        }.joined(separator: "\n")
    }

    static func shorten(_ text: String, _ limit: Int) -> String {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count > limit else { return text }
        return trimmedEnd(String(String.UnicodeScalarView(scalars.prefix(limit - 1)))) + "…"
    }

    static func shortenMarkdown(_ text: String, _ limit: Int) -> String {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count > limit else { return text }
        var cut = Array(scalars.prefix(limit - 1))
        if let line = cut.lastIndex(of: "\n"), line > limit / 2 {
            cut = Array(cut[..<line])
        } else if let space = cut.lastIndex(of: " "), space > limit / 2 {
            cut = Array(cut[..<space])
        }
        let kept = trimmedEnd(String(String.UnicodeScalarView(cut)))
        var open: String?
        for row in kept.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let run = fence(in: row) else { continue }
            if let current = open {
                if run.first == current.first, run.count >= current.count, isClosingFence(row) { open = nil }
            } else {
                open = run
            }
        }
        return open.map { "\(kept)\n\($0)\n\n…" } ?? kept + "…"
    }

    /// The run of three or more backticks or tildes opening a line, after at most three spaces.
    private static func fence(in row: Substring) -> String? {
        let body = row.drop { $0 == " " }
        guard row.count - body.count <= 3, let mark = body.first, mark == "`" || mark == "~" else { return nil }
        let run = body.prefix { $0 == mark }
        return run.count >= 3 ? String(run) : nil
    }

    private static func isClosingFence(_ row: Substring) -> Bool {
        let body = row.drop { $0 == " " }
        guard row.count - body.count <= 3, let mark = body.first, mark == "`" || mark == "~" else { return false }
        return body.drop { $0 == mark }.allSatisfy(\.isWhitespace)
    }

    private static func trimmedEnd(_ text: String) -> String {
        String(text.reversed().drop { $0.isWhitespace }.reversed())
    }
}

/// How long ago a place was last active, as apron-web's `idAgo`: "now", "12m", "9h", "4d", "9w",
/// "2y", each floored.
public enum LastActive {
    public static func words(_ date: Date, now: Date) -> String {
        let minutes = Int((now.timeIntervalSince(date) / 60).rounded(.down))
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        if days < 7 { return "\(days)d" }
        if days / 7 < 52 { return "\(days / 7)w" }
        return "\(max(days / 365, 1))y"
    }
}

/// What the rooms list shows of one room's threads, as apron-web's ThreadList. Under the open
/// room: its joined threads, most recently active first, then Inactive, the quiet ones put away
/// (apron-web #185), then Other Threads, those you have not joined, the first three and "N
/// more…". Under any other room, only joined threads with news, so activity there is not missed,
/// and the thread open in it.
public struct ThreadList: Hashable, Sendable {
    /// One thread as the list weighs it.
    public struct Entry: Hashable, Sendable {
        public var id: String
        public var joined: Bool
        /// Its newest loaded message, else the room's `latest_log_id`, else its creation.
        public var activity: LogID?
        /// Unread replies or mentions of you.
        public var hasNews: Bool

        public init(id: String, joined: Bool, activity: LogID?, hasNews: Bool) {
            self.id = id
            self.joined = joined
            self.activity = activity
            self.hasNews = hasNews
        }
    }

    /// How many threads you have not joined show before "N more…".
    public static let othersShown = 3
    /// How long a joined thread can go without activity before it may move down to Inactive:
    /// long enough to cover a weekend.
    public static let inactiveAfter: TimeInterval = 3 * 24 * 3600
    /// How many of the most recently active joined threads stay up top however quiet, so a room
    /// of a few keeps them all in view.
    public static let activeKept = 5

    public var joined: [String] = []
    /// Inactive: how many there are, and those shown (all, or while folded the open one).
    public var inactiveCount = 0
    public var inactive: [String] = []
    /// Whether the open thread would be under Inactive, whatever side it was opened on: what the
    /// app keeps for `openedQuiet` when another thread is opened.
    public var openThreadIsQuiet: Bool?
    /// Other Threads: how many there are, and those shown.
    public var othersCount = 0
    public var others: [String] = []
    /// The others not shown: the "N more…" row.
    public var moreOthers = 0

    public init() {}

    /// `entries` in any order. `isOpenRoom` is the room open or holding the open thread;
    /// `openThread` the thread open in it, if any, and `openedQuiet` the side it was on when it
    /// was opened, where it stays until another is, so reading it never moves its row.
    public init(_ entries: [Entry], isOpenRoom: Bool, openThread: String?, othersFolded: Bool, allOthers: Bool,
                now: Date = Date(), inactiveFolded: Bool = true, openedQuiet: Bool? = nil) {
        let ordered = entries.sorted(by: Self.byActivity)
        guard isOpenRoom else {
            joined = ordered.filter { $0.joined && ($0.hasNews || $0.id == openThread) }.map(\.id)
            return
        }
        let mine = ordered.filter(\.joined)
        let quiet = Self.quiet(mine, now: now)
        var sides = Dictionary(uniqueKeysWithValues: mine.map { ($0.id, quiet.contains($0.id)) })
        if let openThread, sides[openThread] != nil {
            openThreadIsQuiet = sides[openThread]
            sides[openThread] = openedQuiet ?? sides[openThread]
        }
        joined = mine.filter { sides[$0.id] == false }.map(\.id)
        let putAway = mine.filter { sides[$0.id] == true }
        inactiveCount = putAway.count
        inactive = (inactiveFolded ? putAway.filter { $0.id == openThread || $0.hasNews } : putAway).map(\.id)
        let unjoined = ordered.filter { !$0.joined }.map(\.id)
        othersCount = unjoined.count
        let open = unjoined.first { $0 == openThread }
        if othersFolded {
            others = open.map { [$0] } ?? []
        } else {
            others = allOthers ? unjoined : Array(unjoined.prefix(Self.othersShown))
            if let open, !others.contains(open) { others.append(open) }
            moreOthers = unjoined.count - others.count
        }
    }

    /// The joined threads Inactive puts away: past the `activeKept` most recently active, those
    /// quiet since `inactiveAfter` before `now`, to the hour, with nothing unread or mentioning
    /// you. One whose time is not known stays up top.
    static func quiet(_ joined: [Entry], now: Date) -> Set<String> {
        let millis = { (entry: Entry) in entry.activity.flatMap { Double($0.text) } }
        let newest = Set(joined.sorted { (millis($0) ?? .infinity) > (millis($1) ?? .infinity) }.prefix(activeKept).map(\.id))
        let hour = 3_600_000.0
        let since = ((now.timeIntervalSince1970 * 1000 - inactiveAfter * 1000) / hour).rounded(.down) * hour
        return Set(joined.filter { entry in
            guard !newest.contains(entry.id), !entry.hasNews, let at = millis(entry) else { return false }
            return at < since
        }.map(\.id))
    }

    /// apron-web's `byActivity`: most recently active first, ones with nothing known last, ties by
    /// `room_id`.
    public static func byActivity(_ lhs: Entry, _ rhs: Entry) -> Bool {
        switch (lhs.activity, rhs.activity) {
        case let (left?, right?) where left != right: return left > right
        case (nil, .some): return false
        case (.some, nil): return true
        default: return codePointLess(lhs.id, rhs.id)
        }
    }
}

extension ServerSession {
    /// When a thread was last active, for the rooms list's order: its newest loaded message, else
    /// the newest `log_id` the server has said its log holds, else its creation (its `room_id`
    /// when that is a log position, else its record's `log_id`).
    public func activity(of roomID: String) -> LogID? {
        timeline(roomID).last?.messageID ?? store.latestLogID(of: roomID) ?? LogID(roomID) ?? store.room(roomID)?.logID
    }

    /// When a thread you have not joined was last active, for "4d": what the server listed.
    public func lastActive(of roomID: String) -> Date? {
        (timeline(roomID).last?.messageID ?? store.latestLogID(of: roomID)).map { Date(timeIntervalSince1970: (Double($0.text) ?? 0) / 1000) }
    }

    /// One room's threads as the rooms list shows them, with `openRoomID` the room or thread open.
    public func threadList(of node: RoomNode, open openRoomID: String?, othersFolded: Bool = false, allOthers: Bool = false,
                           now: Date = Date(), inactiveFolded: Bool = true, openedQuiet: Bool? = nil) -> ThreadList {
        let openRoom = openRoomID.map { store.room($0)?.parentRoomID ?? $0 }
        let entries = node.threadIDs.map { id in
            ThreadList.Entry(id: id, joined: joinedRoomIDs.contains(id), activity: activity(of: id),
                             hasNews: unreadCount(in: id) > 0 || mentionCount(in: id) > 0)
        }
        return ThreadList(entries, isOpenRoom: openRoom == node.roomID, openThread: openRoomID == openRoom ? nil : openRoomID,
                          othersFolded: othersFolded, allOthers: allOthers, now: now, inactiveFolded: inactiveFolded, openedQuiet: openedQuiet)
    }

    /// Whether a room is a thread without a title, which shows as "Untitled".
    public func isUntitled(_ roomID: String) -> Bool {
        guard let room = store.room(roomID), room.parentRoomID != nil else { return false }
        return (room.title?.stringValue ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// An open thread's replies in its header, as apron-web's RoomHeader: "1 reply", "12 replies",
    /// and "12+ replies" while older ones are still to load. Nil until its history has loaded.
    public func replyWords(in roomID: String) -> String? {
        guard store.room(roomID)?.parentRoomID != nil, let history = histories[roomID], history.olderBefore != nil || !history.more else { return nil }
        let count = timeline(roomID).count
        let more = canLoadOlder(roomID)
        return "\(count)\(more ? "+" : "") \(count == 1 && !more ? "reply" : "replies")"
    }

    /// A thread of the room already started from the message: one this device started from it,
    /// or one loaded from its start whose first message replies to it, by apron-web's convention.
    public func thread(startedFrom messageID: LogID, in roomID: String) -> String? {
        if let started = startedThreads[messageID], store.room(started) != nil { return started }
        return threadIDs(in: roomID).first { id in
            histories[id] != nil && !canLoadOlder(id) && timeline(id).first?.replyTo == messageID
        }
    }

    /// Starts a thread from a message with what the form holds (§4.2.4), and keeps which message
    /// it came from, so Start Thread on it again opens it. The thread's first reply is what links
    /// back: the app opens it with its composer replying to the message.
    public func startThread(from message: MessageSnapshot, title: String, description: String) async throws -> String? {
        let thread = try await createRoom(title: title, description: description, parentRoomID: message.roomID)
        if let thread { startedThreads[message.messageID] = thread }
        return thread
    }
}
