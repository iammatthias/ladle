import Foundation

/// A message of yours with reactions you have not seen, and how many: one per person whose
/// reaction set on it is new.
public struct UnseenReactions: Hashable, Sendable {
    public var messageID: LogID
    public var count: Int
}

/// New reactions to your own messages (`SeenReactions`), Ladle's own. A reaction set counts when
/// it is someone else's, not empty (a removal), on a loaded message of yours (renames included),
/// and logged past its room's baseline and its message's mark. History pages and catch-ups count
/// as live ones do: they are what happened while you were away. Reactions to a message not
/// loaded can't be told to be yours, so they wait until it loads.
extension ServerSession {
    /// The room's messages with unseen reactions, oldest first.
    public func unseenReactions(in roomID: String) -> [UnseenReactions] {
        guard let key = arrangementKey, let baseline = seenReactions.baseline(of: roomID, key) else { return [] }
        return timeline(roomID).compactMap { message in
            guard isYou(message.from.userID) else { return nil }
            let count = unseenSets(on: message.messageID, past: baseline, key).count
            return count > 0 ? UnseenReactions(messageID: message.messageID, count: count) : nil
        }
    }

    public func unseenReactionCount(in roomID: String) -> Int {
        unseenReactions(in: roomID).reduce(0) { $0 + $1.count }
    }

    /// Where the room's jump to new reactions goes: the oldest message with any.
    public func nextUnseenReaction(in roomID: String) -> LogID? { unseenReactions(in: roomID).first?.messageID }

    /// The messages were on screen: their reactions are seen.
    public func markReactionsSeen(_ messageIDs: some Sequence<LogID>) {
        guard let key = arrangementKey else { return }
        var marks: [LogID: LogID] = [:]
        for messageID in messageIDs {
            if let newest = store.reactionSets(on: messageID).map(\.logID).max() { marks[messageID] = newest }
        }
        if !marks.isEmpty { seenReactions.see(marks, key) }
    }

    private func unseenSets(on messageID: LogID, past baseline: LogID, _ key: ArrangementKey) -> [ReactionSet] {
        let floor = max(baseline, seenReactions.mark(on: messageID, key) ?? baseline)
        return store.reactionSets(on: messageID).filter { !$0.emojis.isEmpty && !isYou($0.from.userID) && $0.logID > floor }
    }

    /// Gives each room among `roomIDs` that has none its baseline: its head as the server last
    /// said it (`latest_log_id`). Only a listing, a room record or a history page says it, never
    /// a live record, so a reaction arriving live after the first sight stays new.
    func noteFirstSight(_ roomIDs: some Sequence<String>) {
        guard let key = arrangementKey else { return }
        var heads: [String: LogID] = [:]
        for roomID in roomIDs where seenReactions.baseline(of: roomID, key) == nil {
            if let latest = store.latestLogID(of: roomID) { heads[roomID] = latest }
        }
        seenReactions.firstSight(heads, key)
    }

    /// A live set that only takes reactions away from a set already seen leaves the message
    /// seen: the marks to raise once it is installed. Before installing, while the sets it
    /// replaces are still there. A page carries no earlier set, so a removal while away counts.
    func seenRemovals(_ sets: [ReactionSet]) -> [LogID: LogID] {
        guard let key = arrangementKey else { return [:] }
        var marks: [LogID: LogID] = [:]
        for set in sets where !set.emojis.isEmpty {
            guard let message = store.message(set.messageID), isYou(message.from.userID),
                  let baseline = seenReactions.baseline(of: message.roomID, key),
                  let previous = store.reactionSets(on: set.messageID).first(where: { $0.from.userID == set.from.userID }),
                  previous.logID < set.logID,
                  Set(set.emojis.map(ReactionEntry.key)).isSubset(of: previous.emojis.map(ReactionEntry.key)),
                  unseenSets(on: set.messageID, past: baseline, key).isEmpty else { continue }
            marks[set.messageID] = max(marks[set.messageID] ?? set.logID, set.logID)
        }
        return marks
    }

    func seeRemovals(_ marks: [LogID: LogID]) {
        guard let key = arrangementKey, !marks.isEmpty else { return }
        seenReactions.see(marks, key)
    }
}
