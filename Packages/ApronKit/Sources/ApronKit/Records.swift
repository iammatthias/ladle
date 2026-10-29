/// The logged records a client replays (§2.3, §3.5, §4.2, §4.7) and the decoders that lift them
/// out of frames. Decoding is the boundary: everything here has been validated once, and the
/// store trusts it.

/// A user object (§3.3.1) as the wire gave it, with its `user_id` lifted out for keying.
public struct UserObject: Hashable, Sendable {
    public let userID: String
    public let json: JSONValue

    public init?(_ value: JSONValue?) {
        guard let value, case .object = value, let userID = OpaqueID.validated(value["user_id"]) else { return nil }
        self.userID = userID
        self.json = value
    }
}

/// A room record (§4.2): the client fields only. Delivery fields live in `RoomDelivery`.
public struct RoomRecord: Hashable, Sendable {
    public var roomID: String
    public var logID: LogID?
    public var parentRoomID: String?
    public var isPrivate: Bool?
    public var title: JSONValue?
    public var description: JSONValue?
    public var ext: JSONValue?
}

/// What a frame says about a room as this client sees it (§4.2); never logged.
public struct RoomDelivery: Hashable, Sendable {
    public var latestLogID: LogID?
    /// A complete member list (§4.2.1), as of `latestLogID`.
    public var members: [UserObject]?
    /// The room's retention floor, from `history_log_id` (`retentionFloor`).
    public var floor: LogID?
}

/// The lowest `log_id` a room or a history page says it keeps (§4.2, §4.3): `history_log_id`, or
/// one past `latest_log_id` when it is null, as nothing is kept. Nil when the key is absent.
func retentionFloor(_ value: JSONValue) -> LogID? {
    guard let floor = value["history_log_id"] else { return nil }
    return floor == .null ? LogID(value["latest_log_id"])?.successor : LogID(floor)
}

/// A message snapshot (§3.5), flat. `replyTo` is always the bare reference; an embedded
/// snapshot is lifted out as its own record by `Records`.
public struct MessageSnapshot: Hashable, Sendable {
    public var messageID: LogID
    public var logID: LogID
    public var roomID: String
    public var from: UserObject
    public var body: JSONValue?
    public var replyTo: LogID?
    /// The room this message was in before a move (§4.4); set by the server.
    public var prevRoomID: String?
    public var deleted: Bool?
    public var ext: JSONValue?

    public var isTombstone: Bool { deleted == true }
}

/// A transient notice (§3.5.3): a `message` without `message_id`, shown and never installed.
public struct Notice: Hashable, Sendable {
    public var roomID: String?
    public var from: UserObject
    public var body: JSONValue?
}

/// One user's complete emoji set on one message at one log position (§4.7).
public struct ReactionSet: Hashable, Sendable {
    public var logID: LogID
    public var messageID: LogID
    public var roomID: String?
    public var from: UserObject
    /// Distinct, in arrival order.
    public var emojis: [String]
}

/// One user's membership of one room at one log position (§4.2.2).
public struct Membership: Hashable, Sendable {
    public var logID: LogID
    public var roomID: String
    public var user: UserObject
    public var joined: Bool
}

/// Every record one frame or result carries, partitioned by kind, in install order.
public struct Records: Sendable {
    public var rooms: [(record: RoomRecord, delivery: RoomDelivery)] = []
    public var messages: [MessageSnapshot] = []
    public var embedded: [MessageSnapshot] = []
    public var reactions: [ReactionSet] = []
    public var memberships: [Membership] = []

    public init() {}

    public var isEmpty: Bool {
        rooms.isEmpty && messages.isEmpty && embedded.isEmpty && reactions.isEmpty && memberships.isEmpty
    }
}

// MARK: - Frame classification

/// What a `message` notification's params turn out to be.
public enum MessageFrame: Hashable, Sendable {
    case snapshot(MessageSnapshot, embedded: [MessageSnapshot])
    case notice(Notice)
    case invalid
}

extension Records {
    /// The records in a notification, or nil for a method that carries none.
    public init?(notification: WireNotification) {
        switch notification.method {
        case "message": self = Records(messageParams: notification.params)
        case "room_update": self = Records(roomUpdateParams: notification.params)
        case "reactions": self = Records(reactionsParams: notification.params)
        default: return nil
        }
    }

    /// Records in a `message` notification's params; empty for a notice or an invalid snapshot.
    public init(messageParams params: JSONValue?) {
        self.init()
        if case .snapshot(let snapshot, let embedded) = MessageFrame(params: params) {
            messages = [snapshot]
            self.embedded = embedded
        }
    }

    /// Records in a `room_update` (§4.2.3): `joined` and `updated` room records, `memberships`.
    /// `left` holds no records, and `users` are current objects, not records.
    public init(roomUpdateParams params: JSONValue?) {
        self.init()
        appendRooms(params?["joined"])
        appendRooms(params?["updated"])
        for element in params?["memberships"]?.arrayValue ?? [] {
            memberships += Membership.decode(element)
        }
    }

    /// Records in a `reactions` notification (§4.7).
    public init(reactionsParams params: JSONValue?) {
        self.init()
        reactions = ReactionSet.decode(params)
    }

    /// Records in a `room_list` result (§4.2.1): `joined` and `not_joined` room records.
    public init(roomListResult result: JSONValue) {
        self.init()
        appendRooms(result["joined"])
        appendRooms(result["not_joined"])
    }

    /// Records in a `history` result (§4.3). A missing array is empty; nothing is filtered by
    /// room, since a move snapshot carries its destination.
    public init(historyResult result: JSONValue) {
        self.init()
        appendRooms(result["rooms"])
        for element in result["messages"]?.arrayValue ?? [] {
            if case .snapshot(let snapshot, let embedded) = MessageFrame(params: element) {
                messages.append(snapshot)
                self.embedded += embedded
            }
        }
        for element in result["reactions"]?.arrayValue ?? [] {
            reactions += ReactionSet.decode(element)
        }
        for element in result["memberships"]?.arrayValue ?? [] {
            memberships += Membership.decode(element)
        }
    }

    private mutating func appendRooms(_ value: JSONValue?) {
        for element in value?.arrayValue ?? [] {
            if let room = RoomRecord.decode(element) { rooms.append(room) }
        }
    }
}

// MARK: - Decoders

extension MessageFrame {
    public init(params: JSONValue?) {
        guard let params, case .object = params, let from = UserObject(params["from"]) else {
            self = .invalid
            return
        }
        if params["message_id"] == nil {
            self = .notice(Notice(roomID: OpaqueID.validated(params["room_id"]), from: from,
                                  body: params["body"].flatMap { $0.objectValue == nil ? nil : $0 }))
            return
        }
        guard let messageID = LogID(params["message_id"]), let logID = LogID(params["log_id"]),
              let roomID = OpaqueID.validated(params["room_id"])
        else {
            self = .invalid
            return
        }
        var snapshot = MessageSnapshot(messageID: messageID, logID: logID, roomID: roomID, from: from)
        snapshot.body = params["body"]
        snapshot.ext = params["ext"]
        snapshot.prevRoomID = OpaqueID.validated(params["prev_room_id"])
        if let deleted = params["deleted"] { snapshot.deleted = deleted.boolValue }
        var embedded: [MessageSnapshot] = []
        if let reference = params["reply_to"], let target = LogID(reference["message_id"]) {
            snapshot.replyTo = target
            if reference["log_id"] != nil, case .snapshot(let inner, let innerEmbedded) = MessageFrame(params: reference) {
                embedded.append(inner)
                embedded += innerEmbedded
            }
        }
        self = .snapshot(snapshot, embedded: embedded)
    }
}

extension RoomRecord {
    static func decode(_ value: JSONValue) -> (record: RoomRecord, delivery: RoomDelivery)? {
        guard case .object = value, let roomID = OpaqueID.validated(value["room_id"]) else { return nil }
        var record = RoomRecord(roomID: roomID)
        record.logID = LogID(value["log_id"])
        record.parentRoomID = OpaqueID.validated(value["parent_room_id"])
        record.isPrivate = value["private"]?.boolValue
        record.title = value["title"]
        record.description = value["description"]
        record.ext = value["ext"]
        var delivery = RoomDelivery()
        delivery.latestLogID = LogID(value["latest_log_id"])
        delivery.members = value["members"]?.arrayValue?.compactMap { UserObject($0) }
        delivery.floor = retentionFloor(value)
        return (record, delivery)
    }
}

extension ReactionSet {
    /// One set per element of `reactions[]`; a compacted record carries several (§4.3.4).
    static func decode(_ value: JSONValue?) -> [ReactionSet] {
        guard let value, let logID = LogID(value["log_id"]), let messageID = LogID(value["message_id"]),
              let elements = value["reactions"]?.arrayValue
        else { return [] }
        let roomID = OpaqueID.validated(value["room_id"])
        return elements.compactMap { element in
            guard let from = UserObject(element["from"]), let emojis = element["emojis"]?.arrayValue else { return nil }
            var seen = Set<String>()
            let distinct = emojis.compactMap(\.stringValue).filter { seen.insert($0).inserted }
            return ReactionSet(logID: logID, messageID: messageID, roomID: roomID, from: from, emojis: distinct)
        }
    }
}

extension Membership {
    /// One membership per element of `members[]`, each at the record's `log_id`.
    static func decode(_ value: JSONValue) -> [Membership] {
        guard let logID = LogID(value["log_id"]), let roomID = OpaqueID.validated(value["room_id"]),
              let elements = value["members"]?.arrayValue
        else { return [] }
        return elements.compactMap { element in
            guard let user = UserObject(element["user"]), let joined = element["joined"]?.boolValue else { return nil }
            return Membership(logID: logID, roomID: roomID, user: user, joined: joined)
        }
    }
}
