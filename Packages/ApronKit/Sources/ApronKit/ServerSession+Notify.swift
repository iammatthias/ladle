import Foundation

/// What this session hands `MessageAlerts`: the messages from others that arrive on its
/// connection, with what it knows about each, and how far you read each room.
extension ServerSession {
    /// The account notification settings are kept for (`NotificationSettings.account`); nil signed out.
    public var notifyAccount: String? {
        you.map { NotificationSettings.account(server: record.id, userID: $0.userID, guest: isGuest) }
    }

    /// Your notifications are silenced here: paused, or your status is do not disturb, which
    /// silences this device as a pause does (apron-web's `pageSilenced`).
    public var silenced: Bool { pause != nil || chosenStatus == "dnd" }

    /// Unread messages from others in the joined rooms and threads, the app badge's share of this
    /// server, as apron-web's `UnreadTracker.total` (muted rooms count too).
    public var unreadTotal: Int {
        roomTree.reduce(0) { total, node in
            total + ([node.roomID] + node.threadIDs.filter(joinedRoomIDs.contains)).reduce(0) { $0 + unreadCount(in: $1) }
        }
    }

    /// What is new in the joined rooms and threads other than `pane`, as apron-web's
    /// `countElsewhere` (#84): the phone's back button carries it, as a tag of unread messages,
    /// or of mentions when any mention you.
    public func newsElsewhere(than pane: String) -> (unread: Int, mentions: Int) {
        var news = (unread: 0, mentions: 0)
        for node in roomTree {
            for roomID in [node.roomID] + node.threadIDs.filter(joinedRoomIDs.contains) where roomID != pane {
                news.unread += unreadCount(in: roomID)
                news.mentions += mentionCount(in: roomID)
            }
        }
        return news
    }

    /// The messages of a live `message` frame that notify: new messages from others, and edits
    /// that newly mention you. `before` is each message's snapshot before the frame was installed.
    func arrivals(_ messages: [MessageSnapshot], before: [LogID: MessageSnapshot]) -> [Arrival] {
        guard let you, let account = notifyAccount else { return [] }
        return messages.compactMap { message in
            guard !message.isTombstone, !isYou(message.from.userID) else { return nil }
            let earlier = before[message.messageID]
            let mentioned = message.mentions(you.userID)
            let new = earlier == nil && message.logID == message.messageID
            guard new || (mentioned && earlier?.mentions(you.userID) == false) else { return nil }
            let roomID = message.roomID
            let parent = store.room(roomID)?.parentRoomID
            let rooms = [roomID] + (parent.map { [$0] } ?? [])
            let replied = message.replyTo.flatMap(store.message)
            let facts = ArrivalFacts(
                mentioned: mentioned,
                repliesToYou: replied.map { !$0.isTombstone && isYou($0.from.userID) } ?? false,
                inPrivate: rooms.contains { store.room($0)?.isPrivate == true },
                inJoined: rooms.contains(where: joinedRoomIDs.contains),
                muted: mute(of: roomID) != nil,
                silenced: silenced,
                onScreen: isOnScreen(roomID))
            return Arrival(server: record.id, account: account, roomID: roomID, messageID: message.messageID,
                           sender: users.plainName(for: message.from), room: title(of: roomID),
                           namedForMembers: isNamedForMembers(roomID), body: Arrival.body(of: message.body), facts: facts)
        }
    }
}
