/// One record of a room's log at its `log_id`, as apron-web's `log.ts` keeps them: a room record,
/// a message snapshot, one user's reaction set, or one user's membership. A reaction or
/// membership record of several users is several entries at one `log_id`.
public enum LogEntry: Hashable, Sendable {
    case room(RoomRecord)
    case message(MessageSnapshot)
    case reaction(ReactionSet)
    case membership(Membership)

    public var logID: LogID {
        switch self {
        case .room(let record): record.logID!
        case .message(let snapshot): snapshot.logID
        case .reaction(let set): set.logID
        case .membership(let membership): membership.logID
        }
    }
}

extension LogEntry {
    /// The most entries one page holds (apron-web's `PAGE_LIMIT`).
    public static let pageLimit = 200

    /// The page of an ascending log that a `history` request with these bounds (inclusive) selects
    /// (§4.3.2), as apron-web's `sliceLog`: the oldest `limit` with `after`, else the newest; `more`
    /// when the bounds hold more in that direction. Entries at one `log_id` are one record, so a
    /// page takes all of them or none, even past `limit`.
    public static func slice(_ log: [LogEntry], after: LogID? = nil, before: LogID? = nil, limit: Int) -> (page: ArraySlice<LogEntry>, more: Bool) {
        let start = after.map { bound in log.firstIndex { $0.logID >= bound } ?? log.count } ?? 0
        let end = before.map { bound in log.firstIndex { $0.logID > bound } ?? log.count } ?? log.count
        guard end > start else { return ([], false) }
        var from = start
        var to = end
        if after != nil {
            to = min(end, start + limit)
            while to < end, log[to].logID == log[to - 1].logID { to += 1 }
        } else {
            from = max(start, end - limit)
            while from > start, log[from - 1].logID == log[from].logID { from -= 1 }
        }
        return (log[from..<to], to - from < end - start)
    }
}

extension Records {
    /// A page of entries as the records a `history` result carries, to install.
    init(entries: some Sequence<LogEntry>) {
        self.init()
        for entry in entries {
            switch entry {
            case .room(let record): rooms.append((record, RoomDelivery()))
            case .message(let snapshot): messages.append(snapshot)
            case .reaction(let set): reactions.append(set)
            case .membership(let membership): memberships.append(membership)
            }
        }
    }
}
