import Foundation

/// What a timeline shows, in order: day dividers, messages, the New line, a card per thread at
/// the point the thread was created, and queued messages last.
public enum TimelineItem: Identifiable, Sendable {
    /// `continues` is true when the previous row is the same author within five minutes.
    case message(MessageSnapshot, continues: Bool)
    case day(Date)
    case unreadLine
    case thread(roomID: String)
    case pending(ServerSession.PendingMessage)

    public var id: String {
        switch self {
        case .message(let message, _): message.messageID.text
        case .day(let date): "day-\(date.timeIntervalSince1970)"
        case .unreadLine: "unread"
        case .thread(let roomID): "thread-" + roomID
        case .pending(let pending): "pending-" + pending.id
        }
    }
}

extension ServerSession {
    /// A thread is placed after the last message older than its creation: its `room_id` when that
    /// is a log position, else its record's `log_id`.
    public func timelineItems(_ roomID: String, lineBefore: LogID?, calendar: Calendar = .current) -> [TimelineItem] {
        let threads = threadIDs(in: roomID)
            .compactMap { id in (LogID(id) ?? store.room(id)?.logID).map { (position: $0, roomID: id) } }
            .sorted { $0.position < $1.position }
        var items: [TimelineItem] = []
        var pendingThreads = threads[...]
        var previous: MessageSnapshot?
        var day: Date?
        for message in timeline(roomID) {
            while let thread = pendingThreads.first, thread.position < message.messageID {
                items.append(.thread(roomID: thread.roomID))
                pendingThreads.removeFirst()
                previous = nil
            }
            let start = calendar.startOfDay(for: message.date)
            if start != day {
                items.append(.day(start))
                day = start
                previous = nil
            }
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
        items += pendingThreads.map { .thread(roomID: $0.roomID) }
        items += outbox.filter { $0.roomID == roomID }.map(TimelineItem.pending)
        return items
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

/// A user's shown status (§4.5.1): their object's `status`, `invisible` showing as offline and
/// an unknown value as online. The app gives each its own shape and color.
public enum Presence: String, Sendable {
    case online, idle, dnd, offline

    public init?(_ user: JSONValue?) {
        guard let value = user?["status"]?.stringValue else { return nil }
        self = Presence(rawValue: value) ?? (value == "invisible" ? .offline : .online)
    }

    public var label: String {
        switch self {
        case .online: "Online"
        case .idle: "Idle"
        case .dnd: "Do not disturb"
        case .offline: "Offline"
        }
    }
}

extension ServerSession {
    public func presence(of userID: String) -> Presence? { Presence(users.user(userID)) }
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
        let policy = mediaPolicy
        return timeline(roomID).flatMap { message in
            message.embedList.enumerated().compactMap { index, embed -> MediaItem? in
                guard case .image(let image) = embed.upload, policy.allowsMedia(image.url) else { return nil }
                return MediaItem(id: MediaItem.id(message, index), media: image.url,
                                 original: embed.url.flatMap { policy.allowsMedia($0) ? $0 : nil },
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
