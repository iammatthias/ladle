/// The client-side record stores (§2.3, wire/README.md "Records, replay, and the logical
/// projection"): one room record per `room_id`, one message snapshot per `message_id`, one
/// reaction set per `(message_id, user_id)`, one membership per `(room_id, user_id)`.
///
/// A record replaces the stored one only when its `log_id` is numerically greater, or when it is a
/// tombstone at an equal `log_id`. Source and arrival order never matter. A room record without
/// `log_id` always replaces. Replacement is whole. Messages are indexed by their current
/// `room_id`, so a move re-homes a message instead of duplicating it.
public struct ReplayStore: Sendable, Equatable {
    private var rooms: [String: RoomRecord] = [:]
    private var messages: [LogID: MessageSnapshot] = [:]
    /// `message_id`s currently homed in each room.
    private var homes: [String: Set<LogID>] = [:]
    /// Per message, per `user_id`.
    private var reactions: [LogID: [String: ReactionSet]] = [:]
    private var members: [String: MemberState] = [:]
    /// Each room's retention floor (§4.3): the lowest `log_id` it still keeps. Never lowered.
    private var floors: [String: LogID] = [:]

    private struct MemberEntry: Hashable, Sendable {
        var user: UserObject
        var joined: Bool
        /// Absent for a member a complete list gave.
        var logID: LogID?
    }

    /// A room's member list: seeded from a complete `members` listing as of `asOf`, kept
    /// current by memberships above it.
    private struct MemberState: Hashable, Sendable {
        var asOf: LogID?
        var entries: [String: MemberEntry] = [:]
    }

    public init() {}

    // MARK: Install

    /// Installs every record in a frame's worth of records. Order within a frame is irrelevant
    /// under the replay rule, except that a room's member list is seeded with its record.
    public mutating func apply(_ records: Records) {
        for (record, delivery) in records.rooms {
            put(room: record)
            if let list = delivery.members { seedMembers(of: record.roomID, with: list, asOf: delivery.latestLogID) }
        }
        for snapshot in records.messages { put(message: snapshot) }
        for snapshot in records.embedded { put(message: snapshot) }
        for set in records.reactions { put(reaction: set) }
        for membership in records.memberships { put(membership: membership) }
    }

    /// Returns whether the record replaced the stored one.
    @discardableResult
    public mutating func put(room record: RoomRecord) -> Bool {
        if let current = rooms[record.roomID], let incoming = record.logID, let stored = current.logID, incoming <= stored {
            return false
        }
        rooms[record.roomID] = record
        return true
    }

    /// At an equal `log_id` a tombstone wins over content (§2.3, §4.4); a tombstone never loses
    /// to another tombstone at the same position.
    @discardableResult
    public mutating func put(message snapshot: MessageSnapshot) -> Bool {
        if let floor = floors[snapshot.roomID], snapshot.logID < floor { return false }
        if let current = messages[snapshot.messageID] {
            if snapshot.logID < current.logID { return false }
            if snapshot.logID == current.logID, !snapshot.isTombstone || current.isTombstone { return false }
            if current.roomID != snapshot.roomID { unhome(snapshot.messageID, from: current.roomID) }
        }
        messages[snapshot.messageID] = snapshot
        homes[snapshot.roomID, default: []].insert(snapshot.messageID)
        return true
    }

    @discardableResult
    public mutating func put(reaction set: ReactionSet) -> Bool {
        if let current = reactions[set.messageID]?[set.from.userID], set.logID <= current.logID { return false }
        reactions[set.messageID, default: [:]][set.from.userID] = set
        return true
    }

    /// A membership at or below the member list's position is already in the list (§4.2.1).
    @discardableResult
    public mutating func put(membership: Membership) -> Bool {
        var state = members[membership.roomID] ?? MemberState()
        if let asOf = state.asOf, membership.logID <= asOf { return false }
        if let current = state.entries[membership.user.userID]?.logID, membership.logID <= current { return false }
        state.entries[membership.user.userID] = MemberEntry(user: membership.user, joined: membership.joined, logID: membership.logID)
        members[membership.roomID] = state
        return true
    }

    /// Starts a room's member list from a complete `members` listing, current as of `asOf`.
    /// Memberships already received above `asOf` stay on top; without a position, the list
    /// replaces everything and every membership overrides it.
    public mutating func seedMembers(of roomID: String, with list: [UserObject], asOf: LogID?) {
        var state = MemberState(asOf: asOf)
        for user in list { state.entries[user.userID] = MemberEntry(user: user, joined: true) }
        if let asOf, let current = members[roomID] {
            for (userID, entry) in current.entries where entry.logID.map({ $0 > asOf }) == true {
                state.entries[userID] = entry
            }
        }
        members[roomID] = state
    }

    /// Raises a room's retention floor and drops the message snapshots below it with their
    /// reactions: the server has expired them (§4.3). A lower floor than the kept one is ignored,
    /// so pages that arrive out of order never bring expired history back.
    public mutating func raiseFloor(of roomID: String, to floor: LogID) {
        guard floors[roomID].map({ $0 < floor }) ?? true else { return }
        floors[roomID] = floor
        for messageID in homes[roomID] ?? [] where messages[messageID]!.logID < floor {
            messages[messageID] = nil
            reactions[messageID] = nil
            unhome(messageID, from: roomID)
        }
    }

    public func floor(of roomID: String) -> LogID? { floors[roomID] }

    private mutating func unhome(_ messageID: LogID, from roomID: String) {
        homes[roomID]?.remove(messageID)
        if homes[roomID]?.isEmpty == true { homes[roomID] = nil }
    }

    // MARK: Read

    public func room(_ roomID: String) -> RoomRecord? { rooms[roomID] }

    public func message(_ messageID: LogID) -> MessageSnapshot? { messages[messageID] }

    /// Every room with a stored record, a message homed in it, or member state, in string order.
    public var roomIDs: [String] {
        Set(rooms.keys).union(homes.keys).union(members.keys).sorted(by: codePointLess)
    }

    /// Messages currently homed in the room, in numeric `message_id` order.
    public func messages(in roomID: String) -> [MessageSnapshot] {
        (homes[roomID] ?? []).sorted().map { messages[$0]! }
    }

    /// The room's members: the users whose latest membership is a join, each as the list or the
    /// winning membership gave them, sorted by `user_id`. Nil when nothing is known.
    public func members(of roomID: String) -> [UserObject]? {
        guard let state = members[roomID] else { return nil }
        return state.entries.values.filter(\.joined).map(\.user).sorted { codePointLess($0.userID, $1.userID) }
    }

    public struct ReactionSummary: Hashable, Sendable {
        public var emoji: String
        /// In string order.
        public var userIDs: [String]
    }

    /// Reactions per emoji across every user's set, in code point order. Nil for a tombstone, an
    /// unloaded message, or a message without a non-empty set.
    public func reactions(on messageID: LogID) -> [ReactionSummary]? {
        guard let snapshot = messages[messageID], !snapshot.isTombstone, let sets = reactions[messageID] else { return nil }
        var users: [String: Set<String>] = [:]
        for set in sets.values {
            for emoji in set.emojis { users[emoji, default: []].insert(set.from.userID) }
        }
        if users.isEmpty { return nil }
        return users.keys.sorted(by: codePointLess).map { emoji in
            ReactionSummary(emoji: emoji, userIDs: users[emoji]!.sorted(by: codePointLess))
        }
    }

    // MARK: Projection

    /// The README's logical projection, `{"rooms": [...]}`, for comparison against fixtures.
    public func projection() -> JSONValue {
        .object(["rooms": .array(roomIDs.map(projectRoom))])
    }

    private func projectRoom(_ roomID: String) -> JSONValue {
        var out: [String: JSONValue] = ["room_id": .string(roomID)]
        if let record = rooms[roomID] {
            out["log_id"] = record.logID?.json
            out["parent_room_id"] = record.parentRoomID.map(JSONValue.string)
            out["title"] = record.title
            out["description"] = record.description
            out["ext"] = record.ext
        }
        if let list = members(of: roomID) { out["members"] = .array(list.map(\.json)) }
        out["messages"] = .array(messages(in: roomID).map(projectMessage))
        return .object(out)
    }

    private func projectMessage(_ snapshot: MessageSnapshot) -> JSONValue {
        var out: [String: JSONValue] = [
            "message_id": snapshot.messageID.json,
            "log_id": snapshot.logID.json,
            "room_id": .string(snapshot.roomID),
            "from": snapshot.from.json,
        ]
        out["body"] = snapshot.body
        out["reply_to"] = snapshot.replyTo.map { .object(["message_id": $0.json]) }
        out["deleted"] = snapshot.deleted.map(JSONValue.bool)
        out["ext"] = snapshot.ext
        if let summaries = reactions(on: snapshot.messageID) {
            out["reactions"] = .array(summaries.map {
                .object(["emoji": .string($0.emoji), "user_ids": .array($0.userIDs.map(JSONValue.string))])
            })
        }
        return .object(out)
    }
}
