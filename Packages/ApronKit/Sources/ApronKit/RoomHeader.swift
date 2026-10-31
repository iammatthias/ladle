import Foundation

/// The room header's line under the title, as apron-web's RoomHeader subtitle: "Link copied" for a
/// moment after Copy Link, who is typing (on a phone, where it stands for the subtitle), an open
/// thread's replies, once a room's pinned description is put away, its first line, or for an
/// untitled private room who can see it ("Online · only you and Bob can see this room").
public enum HeaderLine: Hashable, Sendable {
    case copied
    case typing(String)
    case replies(String)
    case topic(String)
    case privateRoom(String)

    public var text: String {
        switch self {
        case .copied: "Link copied"
        case .typing(let text), .replies(let text), .topic(let text), .privateRoom(let text): text
        }
    }
}

extension ServerSession {
    /// Edit room or thread, as apron-web's RoomEditor: offered with `rooms` to whoever may write;
    /// who may edit which is the server's to say, and its refusal shows.
    public func mayEdit(_ roomID: String) -> Bool {
        status == .signedIn && server?.has("rooms") == true && mayWrite && store.room(roomID) != nil
    }

    /// A room's title as written, for the edit form: empty for a thread called "Untitled".
    public func editableTitle(of roomID: String) -> String {
        store.room(roomID)?.title?.stringValue ?? ""
    }

    /// Saves a room's or thread's title and description with `room_set` (§4.2.4). A save replaces
    /// every client field, so both go, each left out when emptied, which clears it; `ext`, which
    /// the server merges, is left as it is. The `room_update` that follows is the truth.
    public func editRoom(_ roomID: String, title: String, description: String) async throws {
        try require("rooms")
        var params: [String: JSONValue] = ["room_id": .string(roomID)]
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { params["title"] = .string(title) }
        if !description.isEmpty { params["description"] = .string(description) }
        _ = try await request("room_set", .object(params))
    }

    /// Copy Link's link to a room or thread, which any Apron app opens (Appendix A.4).
    public func link(to roomID: String) -> URL? {
        ApronLink(server: record.url, room: roomID).webURL
    }

    /// Where Mark as Read reads a room through: its newest loaded message, else the newest
    /// position the server has said its log holds. Nil when nothing is known.
    public func readMark(of roomID: String) -> LogID? {
        timeline(roomID).last?.messageID ?? store.latestLogID(of: roomID)
    }

    /// Mark as Read from the rooms list: the room read through `readMark(of:)`.
    public func markAllRead(_ roomID: String) async {
        guard let mark = readMark(of: roomID) else { return }
        await markRead(roomID, through: mark)
    }

    /// The header's line. `typing` is who is typing as a phone's subtitle says it, `copied`
    /// whether Copy Link just copied, and `descriptionPutAway` whether the room's pinned
    /// description was put away, which brings its first line here (a room's, not a thread's).
    public func headerLine(_ roomID: String, typing: String?, copied: Bool, descriptionPutAway: Bool) -> HeaderLine? {
        if copied { return .copied }
        if let typing { return .typing(typing) }
        if let replies = replyWords(in: roomID) { return .replies(replies) }
        if descriptionPutAway, store.room(roomID)?.parentRoomID == nil, let description = roomDescription(roomID) {
            let line = MessageText.plain(["text": .string(description), "format": "markdown"])
                .split(separator: "\n").first.map(String.init) ?? ""
            if !line.isEmpty { return .topic(line) }
        }
        return privateLine(roomID).map(HeaderLine.privateRoom)
    }
}
