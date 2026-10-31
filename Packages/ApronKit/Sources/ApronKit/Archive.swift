import Foundation

/// An archive (apron-web's ARCHIVE.md, version 1): what a client held of one server as JSON Lines.
/// A header, then lines that each hold the arrays of a `room_list` result (`joined`,
/// `not_joined`, `users`) or of a `history` result (`rooms`, `messages`, `reactions`,
/// `memberships`), so every record reads as the wire does. Ladle keeps its history on the device
/// in this form too (`KeptHistory`), with its own key in the header.
///
/// A file is untrusted: each record goes through the decoders a server's frames do (§5.4), and a
/// line or record that is not valid is skipped and counted.
public struct Archive: Sendable {
    public static let version = 1

    /// The server it was saved from (its WebSocket URL), as the header says.
    public var server: String = ""
    /// When, as the header's ISO 8601 text.
    public var exportedAt: String = ""
    public var you: UserObject?
    /// The origins its media loads from (ARCHIVE.md §5).
    public var media: [String] = []
    /// The header as written, for keys a reader of this version does not know.
    public var header: JSONValue = [:]
    /// The user objects, a later one of a user replacing an earlier one.
    public var users: [UserObject] = []
    /// The rooms it lists, each once, a later listing replacing an earlier one, in the order first listed.
    public var rooms: [ArchiveRoom] = []
    /// The logged records: room records, messages (reply targets lifted out), reaction sets and memberships.
    public var records = Records()
    /// Lines, and records in them, left out as not valid.
    public var skipped = 0

    public init() {}
}

/// A room an archive lists (ARCHIVE.md §3.1).
public struct ArchiveRoom: Sendable {
    public var record: RoomRecord
    public var joined: Bool
    /// Its `latest_log_id` when it was saved.
    public var latest: LogID?
    public var stretch: ArchiveStretch
    /// Its members' `user_id`s, when listed.
    public var members: [String]?
}

/// Where an archive's stretch of a room's log starts: its `history_log_id` (ARCHIVE.md §3.1).
public enum ArchiveStretch: Hashable, Sendable {
    /// Absent: from the room's oldest record in the archive.
    case fromOldest
    /// `null`: none of the room's log, only its listing.
    case none
    case from(LogID)

    /// Whether a record at `logID` is in the stretch.
    public func holds(_ logID: LogID) -> Bool {
        switch self {
        case .fromOldest: true
        case .none: false
        case .from(let start): logID >= start
        }
    }

    var json: JSONValue? {
        switch self {
        case .fromOldest: nil
        case .none: .null
        case .from(let start): start.json
        }
    }
}

/// Why a file can't be read as an archive, in the words apron-web shows.
public enum ArchiveError: Error, Equatable, CustomStringConvertible {
    case notAnArchive
    case newerVersion

    public var description: String {
        switch self {
        case .notAnArchive: "This file isn’t an Apron export."
        case .newerVersion: "This export is from a newer version of Apron, which this one can’t read."
        }
    }
}

extension Archive {
    /// Reads an archive, as apron-web's `parseArchive`. Lines may end in `\r\n`; blank lines are skipped.
    public init(text: String) throws(ArchiveError) {
        self.init()
        let lines = text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" }
            .map { $0.hasSuffix("\r") ? $0.dropLast() : $0 }
            .filter { !$0.allSatisfy(\.isWhitespace) }
        guard let first = lines.first, let header = Self.object(first), let version = header["apron_archive"] else {
            throw .notAnArchive
        }
        guard version.intValue == Self.version else { throw .newerVersion }
        self.header = header
        server = header["server"]?.stringValue ?? ""
        exportedAt = header["exported_at"]?.stringValue ?? ""
        you = UserObject(header["you"]).map(Self.withoutStatus)
        media = header["media"]?.arrayValue?.compactMap(\.stringValue) ?? []

        var listed: [String: ArchiveRoom] = [:]
        var order: [String] = []
        var users: [String: UserObject] = [:]
        var userOrder: [String] = []
        for text in lines.dropFirst() {
            guard let line = Self.object(text) else {
                skipped += 1
                continue
            }
            var known = false
            func each(_ key: String, _ read: (JSONValue) -> Bool) {
                guard let values = line[key]?.arrayValue else { return }
                known = true
                for value in values where !read(value) { skipped += 1 }
            }
            for (key, joined) in [("joined", true), ("not_joined", false)] {
                each(key) { value in
                    guard let (record, delivery) = RoomRecord.decode(value) else { return false }
                    if listed[record.roomID] == nil { order.append(record.roomID) }
                    let stretch: ArchiveStretch = switch value["history_log_id"] {
                    case nil: .fromOldest
                    case .null?: ArchiveStretch.none
                    case let start?: LogID(start).map(ArchiveStretch.from) ?? .fromOldest
                    }
                    listed[record.roomID] = ArchiveRoom(record: record, joined: joined, latest: delivery.latestLogID, stretch: stretch,
                                                        members: delivery.members?.map(\.userID))
                    return true
                }
            }
            each("users") { value in
                guard let user = UserObject(value) else { return false }
                if users[user.userID] == nil { userOrder.append(user.userID) }
                users[user.userID] = Self.withoutStatus(user)
                return true
            }
            each("rooms") { value in
                guard let (record, _) = RoomRecord.decode(value), record.logID != nil else { return false }
                records.rooms.append((record, RoomDelivery()))
                return true
            }
            each("messages") { value in
                guard case .snapshot(let snapshot, let embedded) = MessageFrame(params: value) else { return false }
                records.messages.append(snapshot)
                records.embedded += embedded
                return true
            }
            each("reactions") { value in
                let sets = ReactionSet.decode(value)
                records.reactions += sets
                return !sets.isEmpty
            }
            each("memberships") { value in
                let entries = Membership.decode(value)
                records.memberships += entries
                return !entries.isEmpty
            }
            if !known { skipped += 1 }
        }
        rooms = order.compactMap { listed[$0] }
        self.users = userOrder.compactMap { users[$0] }
    }

    private static func object(_ line: Substring) -> JSONValue? {
        guard let value = try? JSONValue(parsing: String(line)), value.objectValue != nil else { return nil }
        return value
    }

    /// A user object without `status` and `seen` (§4.5), which are about the moment it was kept.
    static func withoutStatus(_ user: UserObject) -> UserObject {
        guard var fields = user.json.objectValue else { return user }
        fields["status"] = nil
        fields["seen"] = nil
        return UserObject(.object(fields)) ?? user
    }
}

/// What an archive is written from: what a session holds of one server.
public struct ArchiveSource: Sendable {
    public var server: String
    public var you: UserObject?
    /// The server's own origin and its `ext:media` ones.
    public var media: [String]
    public var store: ReplayStore
    public var users: [UserObject]
    public var joined: Set<String>
    /// The rooms to list, each with where its unbroken stretch of records starts.
    public var rooms: [(id: String, stretch: ArchiveStretch)]
    /// More header keys, such as what Ladle keeps of each room's catch-up.
    public var header: [String: JSONValue] = [:]
    /// Whether a message outside every stretch goes when one in them replies to it (ARCHIVE.md
    /// §3.1). A kept log leaves them out: it pages them back from the server with their replies.
    public var references = true

    public init(server: String, you: UserObject?, media: [String], store: ReplayStore, users: [UserObject], joined: Set<String>,
                rooms: [(id: String, stretch: ArchiveStretch)], header: [String: JSONValue] = [:], references: Bool = true) {
        self.server = server
        self.you = you
        self.media = media
        self.store = store
        self.users = users
        self.joined = joined
        self.rooms = rooms
        self.header = header
        self.references = references
    }
}

extension Archive {
    /// The archive's text, as apron-web's `exportArchive` writes one: the header, the listing on
    /// one line, then each record on a line of its own in `log_id` order. A room's records go
    /// from where its stretch starts; a message outside every stretch goes only when one in them
    /// replies to it. Reaction sets on one message fold into one record at the newest set's
    /// `log_id`; a room's memberships at one `log_id` are one record. Keys are in code point
    /// order (`JSONValue.serialized`), where apron-web's follow the order it received them in.
    public static func text(of source: ArchiveSource, exportedAt: Date) -> String {
        let store = source.store
        let stretches = Dictionary(source.rooms.map { ($0.id, $0.stretch) }, uniquingKeysWith: { first, _ in first })
        func within(_ roomID: String, _ logID: LogID) -> Bool { stretches[roomID]?.holds(logID) ?? false }

        var header = source.header
        header["apron_archive"] = .number(String(version))
        header["server"] = .string(source.server)
        header["exported_at"] = .string(Self.timestamp(exportedAt))
        if let you = source.you { header["you"] = withoutStatus(you).json }
        header["media"] = .array(source.media.map(JSONValue.string))
        var lines = [JSONValue.object(header).serialized()]

        func listing(_ roomID: String) -> JSONValue {
            var fields = (store.room(roomID) ?? RoomRecord(roomID: roomID)).json.objectValue ?? [:]
            if let latest = store.latestLogID(of: roomID) { fields["latest_log_id"] = latest.json }
            if let stretch = stretches[roomID]?.json { fields["history_log_id"] = stretch }
            if let members = store.members(of: roomID) { fields["members"] = .array(members.map { ["user_id": .string($0.userID)] }) }
            return .object(fields)
        }
        let ids = source.rooms.map(\.id)
        lines.append(JSONValue.object([
            "joined": .array(ids.filter(source.joined.contains).map(listing)),
            "not_joined": .array(ids.filter { !source.joined.contains($0) }.map(listing)),
            "users": .array(source.users.map { withoutStatus($0).json }),
        ]).serialized())

        var logged: [(logID: LogID, line: JSONValue)] = []
        var kept: [LogID: MessageSnapshot] = [:]
        var memberships: [String: [LogID: [JSONValue]]] = [:]
        for roomID in ids {
            for entry in store.logEntries(of: roomID) where within(roomID, entry.logID) {
                switch entry {
                case .room(let record): logged.append((entry.logID, ["rooms": [record.json]]))
                case .message(let snapshot): kept[snapshot.messageID] = snapshot
                case .reaction: break
                case .membership(let membership):
                    memberships[roomID, default: [:]][membership.logID, default: []].append(["user": membership.user.json, "joined": .bool(membership.joined)])
                }
            }
        }
        let references = source.references
            ? Set(kept.values.compactMap(\.replyTo)).subtracting(kept.keys).sorted().compactMap(store.message) : []
        for snapshot in kept.values.sorted(by: { $0.logID < $1.logID }) + references {
            logged.append((snapshot.logID, ["messages": [snapshot.json]]))
        }
        for snapshot in kept.values {
            let sets = store.reactionSets(on: snapshot.messageID).filter { !$0.emojis.isEmpty && within(snapshot.roomID, $0.logID) }
            guard let newest = sets.map(\.logID).max() else { continue }
            let record: JSONValue = [
                "log_id": newest.json, "message_id": snapshot.messageID.json, "room_id": .string(snapshot.roomID),
                "reactions": .array(sets.map { ["from": $0.from.json, "emojis": .array($0.emojis.map(JSONValue.string))] }),
            ]
            logged.append((newest, ["reactions": [record]]))
        }
        for (roomID, records) in memberships {
            for (logID, members) in records {
                logged.append((logID, ["memberships": [["log_id": logID.json, "room_id": .string(roomID), "members": .array(members)]]]))
            }
        }
        // Stable, so records at one `log_id` keep the order they were gathered in.
        let ordered = logged.enumerated().sorted { ($0.element.logID, $0.offset) < ($1.element.logID, $1.offset) }
        lines += ordered.map { $0.element.line.serialized() }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `2026-10-27T12:00:00.000Z`, as JavaScript's `toISOString`.
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

extension RoomRecord {
    /// The record's client fields as the wire carries them (§4.2).
    public var json: JSONValue {
        var fields: [String: JSONValue] = ["room_id": .string(roomID)]
        fields["log_id"] = logID?.json
        fields["parent_room_id"] = parentRoomID.map(JSONValue.string)
        fields["private"] = isPrivate.map(JSONValue.bool)
        fields["title"] = title
        fields["description"] = description
        fields["ext"] = ext
        return .object(fields)
    }
}

extension MessageSnapshot {
    /// The snapshot as the wire carries it (§3.5), its `reply_to` the bare reference.
    public var json: JSONValue {
        var fields: [String: JSONValue] = [
            "message_id": messageID.json, "log_id": logID.json, "room_id": .string(roomID), "from": from.json,
        ]
        fields["body"] = body
        fields["reply_to"] = replyTo.map { ["message_id": $0.json] }
        fields["prev_room_id"] = prevRoomID.map(JSONValue.string)
        fields["deleted"] = deleted.map(JSONValue.bool)
        fields["ext"] = ext
        return .object(fields)
    }
}
