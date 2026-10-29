import ApronKit
import Foundation

/// What a timeline shows, in order: day dividers, messages, the New line, a card per thread at
/// the point the thread was created, and queued messages last.
enum TimelineItem: Identifiable {
    /// `continues` is true when the previous row is the same author within five minutes.
    case message(MessageSnapshot, continues: Bool)
    case day(Date)
    case unreadLine
    case thread(roomID: String)
    case pending(ServerSession.PendingMessage)

    var id: String {
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
    func timelineItems(_ roomID: String, lineBefore: LogID?, calendar: Calendar = .current) -> [TimelineItem] {
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

    func threadIDs(in roomID: String) -> [String] {
        store.roomIDs.filter { store.room($0)?.parentRoomID == roomID }
    }

    /// Unread messages from others that mention this user.
    func mentionCount(in roomID: String) -> Int {
        guard let you else { return 0 }
        let read = readThrough(roomID)
        return timeline(roomID).count { message in
            !isYou(message.from.userID) && message.mentions(you.userID) && read.map { $0 < message.messageID } ?? true
        }
    }

    func isPrivate(_ roomID: String) -> Bool { store.room(roomID)?.isPrivate == true }

    func roomDescription(_ roomID: String) -> String? {
        store.room(roomID)?.description?.stringValue.flatMap { $0.isEmpty ? nil : TextDirection.withoutOverrides($0) }
    }

    /// The people in a room, online first, each section by name.
    func memberSections(_ roomID: String) -> [(title: String, people: [UserObject])] {
        let people = (store.members(of: roomID) ?? []).map { users.user($0.userID).flatMap(UserObject.init) ?? $0 }
            .sorted { displayName(for: $0).localizedCaseInsensitiveCompare(displayName(for: $1)) == .orderedAscending }
        let online = people.filter { (presence(of: $0.userID) ?? .offline) != .offline }
        let offline = people.filter { (presence(of: $0.userID) ?? .offline) == .offline }
        return [("Online", online), ("Offline", offline)].filter { !$0.1.isEmpty }
    }
}

extension MessageSnapshot {
    /// `message_id` is the creation time in milliseconds (§2.2).
    var date: Date { Date(timeIntervalSince1970: (Double(messageID.text) ?? 0) / 1000) }

    /// `log_id == message_id` marks the creation (§2.2); a later snapshot is an edit or a move.
    /// A move carries `prev_room_id`, so it is not an edit.
    var isEdited: Bool { logID != messageID && prevRoomID == nil }

    var plainText: String { body?["text"]?.stringValue ?? "" }

    var mentionIDs: [String] { body?["mentions"]?.arrayValue?.compactMap(\.stringValue) ?? [] }

    func mentions(_ userID: String) -> Bool { mentionIDs.contains(userID) }
}
