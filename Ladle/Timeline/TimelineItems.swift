import ApronKit
import Foundation

/// What a timeline shows, in order: messages, the read line, and a card per thread at the point
/// the thread was created.
enum TimelineItem: Identifiable {
    /// `continues` is true when the previous row is the same author within five minutes.
    case message(MessageSnapshot, continues: Bool)
    case unreadLine
    case thread(roomID: String)

    var id: String {
        switch self {
        case .message(let message, _): message.messageID.text
        case .unreadLine: "unread"
        case .thread(let roomID): "thread-" + roomID
        }
    }
}

extension ServerSession {
    /// A thread is placed after the last message older than its creation: its `room_id` when that
    /// is a log position, else its record's `log_id`.
    func timelineItems(_ roomID: String) -> [TimelineItem] {
        let threads = store.roomIDs
            .compactMap { store.room($0) }
            .filter { $0.parentRoomID == roomID }
            .compactMap { room in (LogID(room.roomID) ?? room.logID).map { (position: $0, roomID: room.roomID) } }
            .sorted { $0.position < $1.position }
        let cursor = readCursors[roomID]
        var items: [TimelineItem] = []
        var pendingThreads = threads[...]
        var previous: MessageSnapshot?
        var placedUnreadLine = false
        for message in timeline(roomID) {
            while let thread = pendingThreads.first, thread.position < message.messageID {
                items.append(.thread(roomID: thread.roomID))
                pendingThreads.removeFirst()
                previous = nil
            }
            if !placedUnreadLine, let cursor, message.messageID > cursor, message.from.userID != you?.userID {
                items.append(.unreadLine)
                placedUnreadLine = true
                previous = nil
            }
            let continues = previous.map {
                $0.from.userID == message.from.userID && !$0.isTombstone
                    && message.date.timeIntervalSince($0.date) < 300
            } ?? false
            items.append(.message(message, continues: continues))
            previous = message
        }
        items += pendingThreads.map { .thread(roomID: $0.roomID) }
        return items
    }

    /// The newest message in a room, for list previews.
    func lastMessage(in roomID: String) -> MessageSnapshot? {
        timeline(roomID).last { !$0.isTombstone }
    }
}

extension MessageSnapshot {
    /// `message_id` is the creation time in milliseconds (§2.2).
    var date: Date { Date(timeIntervalSince1970: (Double(messageID.text) ?? 0) / 1000) }

    /// `log_id == message_id` marks the creation (§2.2); a later snapshot is an edit or a move.
    var isEdited: Bool { !isTombstone && logID != messageID }

    var plainText: String { body?["text"]?.stringValue ?? "" }
}
