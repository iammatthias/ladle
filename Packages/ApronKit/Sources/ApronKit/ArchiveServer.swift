import Foundation

/// A server in the app that serves one archive read-only (apron-web's `ArchiveServer`, ARCHIVE.md
/// §4), so a `ServerSession` reads an export as it reads a server: it offers only guest sign-in,
/// as the archive's `you`, allowed only to read (`ext:permissions` `write: false`); lists the
/// archive's rooms with `room_list`; pages each room's stretch with `history`, and the joined
/// rooms' together without `room_id`; and refuses every request that would change anything.
/// It advertises `ext:media` with the archive's origins only when asked to (`withImages`), and
/// `ext:archive` with its header. It owns no network connection or storage.
public actor ArchiveServer: FrameTransport {
    public static let capabilities = ["history", "rooms", "reactions", "ext:settings", "ext:permissions", "ext:archive"]
    /// Requests that would change something: refused, where any other unknown request is `unsupported`.
    static let writes: Set<String> = ["message", "reactions", "room_set", "room_join", "room_leave", "me", "status", "command", "push_register", "push_unregister"]
    /// Who reads an archive that was saved signed out.
    static let viewer: JSONValue = ["user_id": "archive_viewer", "name": "Viewer"]

    /// A listed room as served: its latest record, and its log from where the stretch starts.
    struct Served {
        var listed: ArchiveRoom
        var record: RoomRecord
        /// Ascending by `log_id`, from `bound` on.
        var log: [LogEntry]
        /// The effective lower bound (§4.3.3): the stretch's start, or past `latest` when it holds none.
        var bound: LogID
        var latest: LogID
    }

    private let archive: Archive
    private let withImages: Bool
    private let rooms: [String: Served]
    /// Every message's latest snapshot, those outside any stretch included: what `reply_to` embeds.
    private let messages: [LogID: MessageSnapshot]
    private let users: [String: UserObject]
    private var inbox: [String] = []
    private var reader: CheckedContinuation<String?, Never>?
    private var closed = false

    public init(archive: Archive, withImages: Bool) {
        self.archive = archive
        self.withImages = withImages
        users = Dictionary(archive.users.map { ($0.userID, $0) }, uniquingKeysWith: { $1 })
        var messages: [LogID: MessageSnapshot] = [:]
        var taken: Set<LogID> = []
        for message in archive.records.messages + archive.records.embedded {
            taken.insert(message.logID)
            if messages[message.messageID].map({ message.logID > $0.logID }) ?? true { messages[message.messageID] = message }
        }
        self.messages = messages
        // Each room's entries, a record at each position once: an archive may repeat one.
        var entries: [String: [String: LogEntry]] = [:]
        func add(_ roomID: String?, _ key: String, _ entry: LogEntry) {
            guard let roomID else { return }
            taken.insert(entry.logID)
            entries[roomID, default: [:]]["\(entry.kind)\n\(entry.logID.text)\n\(key)"] = entry
        }
        for message in messages.values { add(message.roomID, message.messageID.text, .message(message)) }
        // A reaction set is in the room its message is in.
        for set in archive.records.reactions { add(messages[set.messageID]?.roomID ?? set.roomID, "\(set.messageID.text)\n\(set.from.userID)", .reaction(set)) }
        for membership in archive.records.memberships { add(membership.roomID, membership.user.userID, .membership(membership)) }
        for (record, _) in archive.records.rooms { add(record.roomID, "", .room(record)) }
        for room in archive.rooms where room.record.logID != nil { add(room.record.roomID, "", .room(room.record)) }

        var served: [String: Served] = [:]
        for listed in archive.rooms {
            let id = listed.record.roomID
            let all = (entries[id] ?? [:]).values.sorted { $0.logID < $1.logID }
            // The room's record: its latest, else one without `log_id`, older than all its records (ARCHIVE.md §3.1).
            var record = all.last { if case .room = $0 { true } else { false } }.flatMap { if case .room(let record) = $0 { record } else { nil } } ?? listed.record
            if record.logID == nil { record.logID = Self.position(before: all.first?.logID ?? listed.latest, taken: taken) }
            let last = [record.logID, listed.latest, all.last?.logID].compactMap(\.self).max()!
            let start: LogID? = switch listed.stretch {
            case .fromOldest: all.first { if case .room = $0 { false } else { true } }?.logID
            case .none: nil
            case .from(let start): start
            }
            let bound = start ?? last.successor!
            served[id] = Served(listed: listed, record: record, log: all.filter { $0.logID >= bound }, bound: bound, latest: last)
        }
        rooms = served
    }

    /// A position below `log` (or 1) that no record of the archive holds.
    private static func position(before log: LogID?, taken: Set<LogID>) -> LogID {
        var position = max(1, (log.flatMap { UInt64($0.text) } ?? 2) - 1)
        while taken.contains(LogID(String(position))!), position > 1 { position -= 1 }
        return LogID(String(position))!
    }

    // MARK: FrameTransport

    public func connect() async throws {
        var ext: [String: JSONValue] = ["settings": ["read_cursors": false]]
        var header: [String: JSONValue] = [:]
        if !archive.server.isEmpty { header["server"] = .string(archive.server) }
        if !archive.exportedAt.isEmpty { header["exported_at"] = .string(archive.exportedAt) }
        ext["archive"] = .object(header)
        var capabilities = Self.capabilities
        if withImages, !archive.media.isEmpty {
            capabilities.append("ext:media")
            ext["media"] = ["origins": .array(archive.media.map(JSONValue.string))]
        }
        deliver(["method": "server", "params": ["apron": 9, "agent": "apron-archive", "auth": ["guest"],
                                                 "capabilities": .array(capabilities.map(JSONValue.string)), "ext": .object(ext)]])
    }

    public func send(_ text: String) async throws {
        if closed { throw FrameTransportError.closed }
        let frame = try JSONValue(parsing: text)
        let method = frame["method"]?.stringValue ?? ""
        if method == "ping" { return deliver(["method": "pong"]) }
        // Notifications go nowhere: no one else is here.
        guard let id = frame["id"] else { return }
        let params = frame["params"] ?? [:]
        func reply(_ result: JSONValue) { deliver(["id": id, "result": result]) }
        func fail(_ code: Int, _ message: String) { deliver(["id": id, "error": ["code": .number(String(code)), "message": .string(message)]]) }
        switch method {
        case "auth":
            if params["scheme"]?.stringValue == "guest" { reply(["you": Self.readOnly(archive.you?.json ?? Self.viewer)]) } else { fail(-32601, "This archive offers only guest sign-in.") }
        case "room_list":
            reply(listRooms(params))
        case "history":
            if params["room_id"] == nil {
                reply(history(joinedLog(), params))
            } else if let room = params["room_id"]?.stringValue.flatMap({ rooms[$0] }) {
                reply(history((room.log, room.bound, room.latest), params))
            } else {
                fail(-32602, "This archive has no such room.")
            }
        default:
            if Self.writes.contains(method) { fail(-32001, "This is a read-only archive: nothing in it can change.") } else { fail(-32601, "Unsupported method") }
        }
    }

    public func receive() async throws -> String {
        if !inbox.isEmpty { return inbox.removeFirst() }
        if closed { throw FrameTransportError.closed }
        guard let next = await withCheckedContinuation({ reader = $0 }) else { throw FrameTransportError.closed }
        return next
    }

    public func close() async {
        closed = true
        reader?.resume(returning: nil)
        reader = nil
    }

    private func deliver(_ frame: JSONValue) {
        let text = frame.serialized()
        if let reader {
            self.reader = nil
            reader.resume(returning: text)
        } else {
            inbox.append(text)
        }
    }

    // MARK: Requests

    /// `room_list` (§4.2.1): the archive's rooms, as joined as they were, the most recently active first.
    private func listRooms(_ params: JSONValue) -> JSONValue {
        let parent = params["parent_room_id"]?.stringValue, exact = params["room_id"]?.stringValue
        let withMembers = params["members"]?.boolValue == true
        let matching = rooms.values
            .filter { room in exact.map { room.record.roomID == $0 } ?? parent.map { room.record.parentRoomID == $0 } ?? true }
            .sorted { $0.latest > $1.latest }
        let joined = matching.filter(\.listed.joined).map { listing($0, withMembers) }
        // Without `parent_room_id` or `room_id`, `not_joined` holds top-level rooms only.
        let notJoined = matching.filter { !$0.listed.joined && (exact != nil || parent != nil || $0.record.parentRoomID == nil) }.map { listing($0, withMembers) }
        var result: [String: JSONValue] = [:]
        if withMembers {
            var seen = Set<String>()
            let ids = matching.flatMap(membersOf).filter { seen.insert($0).inserted }
            result["users"] = .array(ids.map { users[$0]?.json ?? ["user_id": .string($0)] })
        }
        switch params["filter"]?.stringValue {
        case "joined": result["joined"] = .array(joined)
        case "not_joined": result["not_joined"] = .array(notJoined)
        default:
            result["joined"] = .array(joined)
            result["not_joined"] = .array(notJoined)
        }
        return .object(result)
    }

    private func listing(_ room: Served, _ withMembers: Bool) -> JSONValue {
        var fields = room.record.json.objectValue ?? [:]
        fields["latest_log_id"] = room.latest.json
        fields["history_log_id"] = Self.historyLogID(bound: room.bound, latest: room.latest)
        if withMembers { fields["members"] = .array(membersOf(room).map { ["user_id": .string($0)] }) }
        return .object(fields)
    }

    /// `history_log_id` (§4.3.3): the bound, or null when it is past the latest.
    private static func historyLogID(bound: LogID, latest: LogID) -> JSONValue {
        bound > latest ? .null : bound.json
    }

    /// Who had joined: as the archive listed them, else as its memberships leave them.
    private func membersOf(_ room: Served) -> [String] {
        if let members = room.listed.members { return members }
        var joined: [String: Bool] = [:]
        var order: [String] = []
        for membership in archive.records.memberships.sorted(by: { $0.logID < $1.logID }) where membership.roomID == room.record.roomID {
            if joined[membership.user.userID] == nil { order.append(membership.user.userID) }
            joined[membership.user.userID] = membership.joined
        }
        return order.filter { joined[$0] == true }
    }

    /// The joined rooms' logs as one, from the greatest of their bounds: below it, one room's
    /// stretch may have started while another's hadn't.
    private func joinedLog() -> ([LogEntry], LogID, LogID) {
        let joined = rooms.values.filter(\.listed.joined)
        let one = LogID("1")!
        let latest = joined.map(\.latest).max() ?? one
        let bound = joined.map(\.bound).max() ?? one
        return (joined.flatMap { $0.log.filter { $0.logID >= bound } }.sorted { $0.logID < $1.logID }, bound, latest)
    }

    /// `history` (§4.3.2): a slice of a log as apron-web's `historyResult` writes it, each message
    /// carrying the snapshot it replies to.
    private func history(_ room: ([LogEntry], LogID, LogID), _ params: JSONValue) -> JSONValue {
        let (log, bound, latest) = room
        let requested = params["limit"]?.intValue ?? LogEntry.pageLimit
        let limit = requested > 0 ? min(requested, LogEntry.pageLimit) : LogEntry.pageLimit
        let (page, more) = LogEntry.slice(log, after: LogID(params["after"]), before: LogID(params["before"]), limit: limit)
        var rooms: [JSONValue] = [], messages: [JSONValue] = []
        var reactions: [(key: String, logID: LogID, messageID: LogID, roomID: String?, sets: [JSONValue])] = []
        var memberships: [(key: String, logID: LogID, roomID: String, members: [JSONValue])] = []
        for entry in page {
            switch entry {
            case .room(let record): rooms.append(record.json)
            case .message(let snapshot): messages.append(withReply(snapshot))
            case .reaction(let set):
                let key = "\(set.messageID.text)\n\(set.logID.text)"
                let one: JSONValue = ["from": set.from.json, "emojis": .array(set.emojis.map(JSONValue.string))]
                if let index = reactions.firstIndex(where: { $0.key == key }) { reactions[index].sets.append(one) } else {
                    reactions.append((key, set.logID, set.messageID, set.roomID, [one]))
                }
            case .membership(let membership):
                let key = "\(membership.roomID)\n\(membership.logID.text)"
                let one: JSONValue = ["user": membership.user.json, "joined": .bool(membership.joined)]
                if let index = memberships.firstIndex(where: { $0.key == key }) { memberships[index].members.append(one) } else {
                    memberships.append((key, membership.logID, membership.roomID, [one]))
                }
            }
        }
        var result: [String: JSONValue] = [
            "rooms": .array(rooms), "messages": .array(messages),
            "reactions": .array(reactions.map { record in
                var fields: [String: JSONValue] = ["log_id": record.logID.json, "message_id": record.messageID.json, "reactions": .array(record.sets)]
                fields["room_id"] = record.roomID.map(JSONValue.string)
                return .object(fields)
            }),
            "memberships": .array(memberships.map { ["log_id": $0.logID.json, "room_id": .string($0.roomID), "members": .array($0.members)] }),
            "more": .bool(more), "latest_log_id": latest.json, "history_log_id": Self.historyLogID(bound: bound, latest: latest),
        ]
        if let first = page.first, let last = page.last {
            result["first_log_id"] = first.logID.json
            result["last_log_id"] = last.logID.json
        }
        return .object(result)
    }

    /// A message with the snapshot it replies to embedded, when the archive has it, so a quote
    /// shows from any room.
    private func withReply(_ message: MessageSnapshot) -> JSONValue {
        guard let replyTo = message.replyTo, replyTo != message.messageID, let target = messages[replyTo],
              var fields = message.json.objectValue else { return message.json }
        fields["reply_to"] = target.json
        return .object(fields)
    }

    /// `you` as this server signs one in: allowed only to read.
    private static func readOnly(_ you: JSONValue) -> JSONValue {
        guard var fields = you.objectValue else { return you }
        var ext = fields["ext"]?.objectValue ?? [:]
        ext["permissions"] = ["write": false, "add_members": false, "move_any": false]
        fields["ext"] = .object(ext)
        return .object(fields)
    }
}

extension LogEntry {
    var kind: String {
        switch self {
        case .room: "room"
        case .message: "message"
        case .reaction: "reaction"
        case .membership: "membership"
        }
    }
}
