import Foundation

/// A room or thread the composer's `#` list offers, as apron-web's `RoomSuggestion`.
public struct RoomSuggestion: Hashable, Sendable {
    public var id: String
    public var title: String
    public var isPrivate = false
    public var isThread = false

    public init(id: String, title: String, isPrivate: Bool = false, isThread: Bool = false) {
        self.id = id
        self.title = title
        self.isPrivate = isPrivate
        self.isThread = isThread
    }
}

/// `#room_id` in text (PROTOCOL.md Appendix A.3), as apron-web reads and writes it: the composer's
/// `#` list (`room-autocomplete.ts`) and the room chips in rendered text (`mentionSegments`).
public enum RoomMentions {
    /// The most rooms the list shows, as apron-web's `MAX_MATCHES`.
    public static let limit = 8

    /// The room id being typed at the end of a draft: `#` at the start or after whitespace, then
    /// at least one of apron-web's `ROOM_CHAR` (`[A-Za-z0-9_.-]`).
    public static func query(in draft: String) -> String? {
        let word = draft.reversed().prefix { !$0.isWhitespace }
        guard word.last == "#" else { return nil }
        let typed = String(word.dropLast().reversed())
        guard !typed.isEmpty, typed.allSatisfy(isRoomCharacter) else { return nil }
        return typed
    }

    /// Rooms whose id or title matches, exact first, then those starting with the query, then
    /// those containing it, each by title then id, at most `limit`, as apron-web's `searchRooms`.
    public static func search(_ rooms: [RoomSuggestion], _ query: String) -> [RoomSuggestion] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        func rank(_ room: RoomSuggestion) -> Int? {
            let id = room.id.lowercased(), title = room.title.lowercased()
            if needle.isEmpty || id == needle || title == needle { return 0 }
            if id.hasPrefix(needle) || title.hasPrefix(needle) { return 1 }
            if id.contains(needle) || title.contains(needle) { return 2 }
            return nil
        }
        let ranked = rooms.compactMap { room in rank(room).map { (room, $0) } }
        return ranked.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            let byTitle = lhs.0.title.localizedCompare(rhs.0.title)
            if byTitle != .orderedSame { return byTitle == .orderedAscending }
            return codePointLess(lhs.0.id, rhs.0.id)
        }.prefix(limit).map(\.0)
    }

    /// The draft with the `#` being typed replaced by `#room_id` and a space, which is what is
    /// sent (apron-web's `chipText` and `insertMention`).
    public static func insert(_ roomID: String, into draft: String) -> String {
        guard let typed = query(in: draft) else { return draft }
        return String(draft.dropLast(typed.count + 1)) + "#" + roomID + " "
    }

    private static func isRoomCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || "_.-".contains(character))
    }

    /// `#` not after a letter or digit, then the id Appendix A.3 reads: the longest run of
    /// `[A-Za-z0-9_.+@:-]` starting and ending with a letter, digit or `_` (apron-web's `TEXT_ID`).
    static let reference = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9])#([A-Za-z0-9_](?:[A-Za-z0-9_.+@:-]*[A-Za-z0-9_])?)"#)

    /// The link a room chip opens: a relative Apron link to the room (link.apron.chat SPEC §5).
    public static func link(to roomID: String) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~:@")
        return roomID.addingPercentEncoding(withAllowedCharacters: allowed).flatMap { URL(string: "apron:?room=" + $0) }
    }
}

extension ServerSession {
    /// Every room and thread this session holds a record of, for the composer's `#` list.
    public var roomSuggestions: [RoomSuggestion] {
        store.roomIDs.compactMap { id in
            store.room(id).map { RoomSuggestion(id: id, title: title(of: id), isPrivate: $0.isPrivate == true, isThread: $0.parentRoomID != nil) }
        }
    }

    /// The title a `#room_id` chip shows, for a room this session holds a record of.
    public func referencedTitle(_ roomID: String) -> String? {
        store.room(roomID) == nil ? nil : title(of: roomID)
    }
}

/// Marks a `#room_id` chip in rendered text (`MessageText`); the value is the room id. The run's
/// text is the room's title after `#`, and its link opens the room.
public enum RoomReferenceKey: AttributedStringKey {
    public typealias Value = String
    public static let name = "ApronRoomReference"
}
