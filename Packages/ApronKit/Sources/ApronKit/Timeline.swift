import Foundation

/// What a timeline shows, in order: day dividers, messages, the New line, a card per thread at
/// the point the thread was created, join and leave lines, rename lines, and queued messages last.
public enum TimelineItem: Identifiable, Sendable {
    /// `continues` is true when the previous row is the same author within five minutes.
    case message(MessageSnapshot, continues: Bool)
    case day(Date)
    case unreadLine
    case thread(roomID: String)
    /// Consecutive membership records netted out (`MembershipLines`).
    case members(MembershipLine)
    case renamed(RoomRename)
    case pending(ServerSession.PendingMessage)

    public var id: String {
        switch self {
        case .message(let message, _): message.messageID.text
        case .day(let date): "day-\(date.timeIntervalSince1970)"
        case .unreadLine: "unread"
        case .thread(let roomID): "thread-" + roomID
        case .members(let line): "members-" + line.firstLogID.text
        case .renamed(let rename): "renamed-" + rename.logID.text
        case .pending(let pending): "pending-" + pending.id
        }
    }
}

/// A join and leave line: who a run of membership records comes to. It is keyed by the run's
/// first record, so it stays put as later ones join the run, and shows the last one's time.
public struct MembershipLine: Hashable, Sendable {
    public var firstLogID: LogID
    public var lastLogID: LogID
    public var joined: [UserObject]
    public var left: [UserObject]

    public var date: Date { Date(timeIntervalSince1970: (Double(lastLogID.text) ?? 0) / 1000) }
}

extension ServerSession {
    /// The timeline as apron-web's `buildRoomTimeline`. A thread's card sits after the last message
    /// older than its creation: its `room_id` when that is a log position, else its record's
    /// `log_id`. Membership records and renames sit at their `log_id`s among the messages and
    /// cards, each after a day pill when the day changes. Records with nothing else between them
    /// (a day pill counts) make one line, netted per user; one that nets to nothing leaves no line
    /// and does not break a sender's run. Baseline records are skipped.
    public func timelineItems(_ roomID: String, lineBefore: LogID?, calendar: Calendar = .current) -> [TimelineItem] {
        enum Event {
            case thread(String)
            case rename(RoomRename)
            case membership(MembershipRecord)
            /// At one position a card goes first, then a rename, then a membership, as on the web.
            var rank: Int {
                switch self {
                case .thread: 0
                case .rename: 1
                case .membership: 2
                }
            }
        }
        let threads = threadIDs(in: roomID).compactMap { id in (LogID(id) ?? store.room(id)?.logID).map { ($0, Event.thread(id)) } }
        let renames = store.renames(of: roomID).map { ($0.logID, Event.rename($0)) }
        let memberships = store.membershipLog(of: roomID).filter { !$0.isBaseline }.map { ($0.logID, Event.membership($0)) }
        let events = (threads + renames + memberships).sorted { $0.0 < $1.0 || ($0.0 == $1.0 && $0.1.rank < $1.1.rank) }

        var items: [TimelineItem] = []
        var previous: MessageSnapshot?
        var day: Date?
        var run: [MembershipRecord] = []
        var runDay: Date?
        func date(_ id: LogID) -> Date { Date(timeIntervalSince1970: (Double(id.text) ?? 0) / 1000) }
        func push(day start: Date) {
            guard start != day else { return }
            closeRun()
            items.append(.day(start))
            day = start
            previous = nil
        }
        func closeRun() {
            guard let first = run.first, let last = run.last, let start = runDay else { return }
            let net = MembershipLines.net(run)
            run = []
            guard !net.joined.isEmpty || !net.left.isEmpty else { return }
            push(day: start)
            items.append(.members(MembershipLine(firstLogID: first.logID, lastLogID: last.logID, joined: net.joined, left: net.left)))
            previous = nil
        }
        var pending = events[...]
        func pushGap(before: LogID?) {
            while let (position, event) = pending.first, before.map({ position < $0 }) ?? true {
                pending.removeFirst()
                let start = calendar.startOfDay(for: date(position))
                switch event {
                case .membership(let record):
                    if !run.isEmpty, runDay != start { closeRun() }
                    if run.isEmpty { runDay = start }
                    run.append(record)
                case .rename(let rename):
                    closeRun()
                    push(day: start)
                    items.append(.renamed(rename))
                    previous = nil
                case .thread(let id):
                    closeRun()
                    push(day: start)
                    items.append(.thread(roomID: id))
                    previous = nil
                }
            }
        }
        for message in timeline(roomID) {
            pushGap(before: message.messageID)
            closeRun()
            push(day: calendar.startOfDay(for: message.date))
            if message.messageID == lineBefore {
                items.append(.unreadLine)
                previous = nil
            }
            let continues = previous.map {
                $0.from.userID == message.from.userID && message.date.timeIntervalSince($0.date) < 300
            } ?? false
            items.append(.message(message, continues: continues))
            previous = message
        }
        pushGap(before: nil)
        closeRun()
        items += outbox.filter { $0.roomID == roomID }.map(TimelineItem.pending)
        return items
    }

    /// A join and leave line as the timeline says it, each user named as rows name them.
    public func words(_ line: MembershipLine) -> (text: String, full: String?) {
        MembershipLines.summary(joined: line.joined.map(displayName(for:)), left: line.left.map(displayName(for:)))
    }

    public func threadIDs(in roomID: String) -> [String] {
        store.roomIDs.filter { store.room($0)?.parentRoomID == roomID }
    }

    /// Unread messages from others that mention this user.
    public func mentionCount(in roomID: String) -> Int {
        guard let you else { return 0 }
        let read = readThrough(roomID)
        return timeline(roomID).count { message in
            !isYou(message.from.userID) && message.mentions(you.userID) && read.map { $0 < message.messageID } ?? true
        }
    }

    public func isPrivate(_ roomID: String) -> Bool { store.room(roomID)?.isPrivate == true }

    public func roomDescription(_ roomID: String) -> String? {
        store.room(roomID)?.description?.stringValue.flatMap { $0.isEmpty ? nil : TextDirection.withoutOverrides($0) }
    }

    /// The people in a room, online first, each section by name.
    public func memberSections(_ roomID: String) -> [(title: String, people: [UserObject])] {
        let people = (store.members(of: roomID) ?? []).map { users.user($0.userID).flatMap(UserObject.init) ?? $0 }
            .sorted { displayName(for: $0).localizedCaseInsensitiveCompare(displayName(for: $1)) == .orderedAscending }
        let online = people.filter { (presence(of: $0.userID) ?? .offline) != .offline }
        let offline = people.filter { (presence(of: $0.userID) ?? .offline) == .offline }
        return [("Online", online), ("Offline", offline)].filter { !$0.1.isEmpty }
    }
}

extension MessageSnapshot {
    /// `message_id` is the creation time in milliseconds (§2.2).
    public var date: Date { Date(timeIntervalSince1970: (Double(messageID.text) ?? 0) / 1000) }

    /// `log_id == message_id` marks the creation (§2.2); a later snapshot is an edit or a move.
    /// A move carries `prev_room_id`, so it is not an edit.
    public var isEdited: Bool { logID != messageID && prevRoomID == nil }

    public var plainText: String { body?["text"]?.stringValue ?? "" }

    public var mentionIDs: [String] { body?["mentions"]?.arrayValue?.compactMap(\.stringValue) ?? [] }

    public func mentions(_ userID: String) -> Bool { mentionIDs.contains(userID) }
}

/// A user's shown status (§4.5.1): their object's `status`, `invisible` (your own, chosen) showing
/// as offline, and a value this client does not know as `unknown` (§4.5.2). No status, absent or
/// `""`, is none. The app gives each its own shape and color.
public enum Presence: String, Sendable {
    case online, idle, dnd, offline, unknown

    public init?(_ user: JSONValue?) {
        self.init(status: user?["status"]?.stringValue)
    }

    public init?(status: String?) {
        guard let status, !status.isEmpty else { return nil }
        self = Presence(rawValue: status) ?? (status == "invisible" ? .offline : .unknown)
    }

    public var label: String {
        switch self {
        case .online: "Online"
        case .idle: "Idle"
        case .dnd: "Do not disturb"
        case .offline: "Offline"
        case .unknown: "Unknown status"
        }
    }

    /// A status in words, as apron-web's ProfileCard says it: an unknown one with its value, and
    /// your own invisible as how others see you. Nil for no status.
    public static func words(_ status: String?, yours: Bool) -> String? {
        guard let presence = Presence(status: status) else { return nil }
        if yours, status == "invisible" { return "Invisible · others see you as offline" }
        return presence == .unknown ? "Unknown status: \(status ?? "")" : presence.label
    }
}

extension ServerSession {
    /// Someone's shown status; for you, your chosen one (§4.5.2).
    public func presence(of userID: String) -> Presence? {
        isYou(userID) ? Presence(status: chosenStatus) : Presence(users.user(userID))
    }
}

/// An image upload in a room, as the media viewer pages through them.
public struct MediaItem: Identifiable, Hashable, Sendable {
    public let id: String
    /// What the viewer shows: `og.image`.
    public let media: URL
    /// The file itself, the embed's `url`, for Open Original.
    public let original: URL?
    public let name: String
    public let alt: String?
    public let sender: String
    public let date: Date

    /// A message's embed by position, stable across snapshots of the message.
    public static func id(_ message: MessageSnapshot, _ index: Int) -> String { "\(message.messageID.text)#\(index)" }
}

extension ServerSession {
    /// Every loadable image upload in a room, oldest first, as the web's viewer pages them.
    public func mediaItems(in roomID: String) -> [MediaItem] {
        let gate = mediaGate
        return timeline(roomID).flatMap { message in
            message.embedList.enumerated().compactMap { index, embed -> MediaItem? in
                guard case .image(let image) = embed.upload, gate.allows(image.url) else { return nil }
                return MediaItem(id: MediaItem.id(message, index), media: image.url,
                                 original: embed.url.flatMap { gate.allows($0) ? $0 : nil },
                                 name: embed.name ?? "Image", alt: image.alt, sender: displayName(for: message.from), date: message.date)
            }
        }
    }

    /// Whether showing this message needs the custom emoji catalog: its text could hold a key, or
    /// a reaction is one.
    public func needsEmojiCatalog(_ message: MessageSnapshot) -> Bool {
        guard server?.emojiCatalogURL != nil, emojiCatalog == nil else { return false }
        return EmojiKeys.mayHaveKeys(message.plainText)
            || (store.reactions(on: message.messageID) ?? []).contains { !ReactionEntry.isEmojiSequence($0.emoji) }
    }

    /// Fetches the catalog when the text could hold a key.
    public func loadEmojiCatalog(for text: String?) async {
        if let text, EmojiKeys.mayHaveKeys(text) { await loadEmojiCatalog() }
    }
}
