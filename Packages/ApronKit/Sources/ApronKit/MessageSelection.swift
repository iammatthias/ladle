import Foundation

/// Select mode in one pane (a room or a thread), as apron-web's `MessageSelection` (#14, #54):
/// entered with one message picked, grown by taps and ranges, ended by a move, a copy or Cancel.
public struct MessageSelection: Hashable, Sendable {
    public let roomID: String
    /// Picked, in the order picked.
    public private(set) var ids: [LogID]
    /// The last one picked, which a range fills from.
    public private(set) var last: LogID?
    /// After a move the server partly refused: how many of how many stayed.
    public var denied: Denied?

    public struct Denied: Hashable, Sendable {
        public var failed: Int
        public var total: Int

        /// "2 of 5 couldn’t be moved", as apron-web's SelectionBar says it.
        public var words: String { "\(failed) of \(total) couldn’t be moved" }
    }

    public init(roomID: String, first: LogID) {
        self.roomID = roomID
        ids = [first]
        last = first
    }

    public func contains(_ id: LogID) -> Bool { ids.contains(id) }

    /// "1 message selected", "3 messages selected".
    public var countWords: String { ids.count == 1 ? "1 message selected" : "\(ids.count) messages selected" }

    /// Picks or unpicks one, or with `range` picks every message along `order` from the last
    /// picked to it (apron-web's `rangeBetween`). False once nothing is left picked: select mode ends.
    public mutating func toggle(_ id: LogID, order: [LogID], range: Bool = false) -> Bool {
        denied = nil
        if range, let last {
            if let start = order.firstIndex(of: last), let end = order.firstIndex(of: id) {
                ids = Array(order[min(start, end) ... max(start, end)])
            } else {
                ids = last == id ? [id] : [last, id]
            }
            self.last = id
            return true
        }
        if let index = ids.firstIndex(of: id) {
            ids.remove(at: index)
        } else {
            ids.append(id)
            last = id
        }
        return !ids.isEmpty
    }

    /// Shift+↑ or Shift+↓ (apron-web #219's `extend`): the picked messages become those along
    /// `order` from `anchor`, where the run of keys began, to `id`, both included, so stepping
    /// back the other way gives them up again.
    public mutating func extend(from anchor: LogID, to id: LogID, order: [LogID]) {
        if let start = order.firstIndex(of: anchor), let end = order.firstIndex(of: id) {
            ids = Array(order[min(start, end) ... max(start, end)])
        } else {
            ids = anchor == id ? [id] : [anchor, id]
        }
        last = id
        denied = nil
    }

    /// Select Between: every message along `order` from the earliest picked to the latest
    /// (apron-web's `spanOf`).
    public mutating func fillBetween(order: [LogID]) {
        let indexes = ids.compactMap { order.firstIndex(of: $0) }
        guard indexes.count >= 2, let low = indexes.min(), let high = indexes.max() else { return }
        ids = Array(order[low ... high])
        denied = nil
    }

    /// The picked message that comes first along `order`: what a new thread's title is suggested from.
    public func earliest(order: [LogID]) -> LogID? {
        ids.min { (order.firstIndex(of: $0) ?? .max) < (order.firstIndex(of: $1) ?? .max) }
    }

    /// The picked ones that stay picked after a move refused some.
    mutating func keep(_ failed: [LogID], of total: Int) {
        ids = failed
        last = failed.last
        denied = Denied(failed: failed.count, total: total)
    }
}

/// What a move of a selection came to, as apron-web's `MoveResult`.
public struct SelectionMove: Sendable {
    /// The room moved into, or the new thread, which exists even when not everything moved into it.
    public var roomID: String?
    public var moved: Bool
    /// Why nothing or not everything moved, in the words to show.
    public var problem: String?
    /// The messages moved, but some authors weren't added to the thread.
    public var unadded: String?
}

/// Why a new thread was not made for a selection holding a message you may not move.
public let notMovableWords = "You can only move your own messages, so none were moved"
