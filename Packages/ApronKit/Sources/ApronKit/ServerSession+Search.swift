import Foundation

/// What a search found: the newest matches, whether more matched, and the words they matched.
public struct SearchFound: Sendable {
    public var messages: [MessageSnapshot]
    public var more: Bool
    public var query: SearchQuery

    public static let none = SearchFound(messages: [], more: false, query: SearchQuery(text: "", users: [], rooms: []))
}

/// A result's row, as apron-web's SearchPanel shows one: where the message is, who wrote it,
/// when, and a line of its text with the words searched for marked.
public struct SearchHit: Identifiable, Sendable {
    public var id: LogID { message.messageID }
    public var message: MessageSnapshot
    /// The room's title, or a thread's with its room's after it.
    public var place: String
    public var who: String
    public var parts: [SnippetPart]
}

/// Search Local History, as apron-web's SearchDialog (#137, #166): every message this device holds
/// of the server, kept or loaded (`kept`), as the query is typed.
extension ServerSession {
    /// What the field starts with: the open room's filter, so a search starts narrowed to it.
    public static func searchStart(in roomID: String?) -> String {
        roomID.map { "room:#\($0) " } ?? ""
    }

    /// Under the field: what is searched, as apron-web's `searchNote`.
    public var searchNote: String {
        guard let retention = keeping?.settings.retention, resumable else { return "Messages loaded now." }
        let span: String? = switch retention {
        case .off, .day: "the last day"
        case .week: "the last week"
        case .month: "the last 30 days"
        case .year: "the last year"
        case .forever: nil
        }
        return "Messages kept on this device\(span.map { " from \($0)" } ?? ""), and those loaded now."
    }

    /// How far back history is kept, beside the title ("30 Days"); nil where nothing is kept.
    public var searchKept: String? {
        guard let keeping, resumable else { return nil }
        return keeping.settings.retention.title
    }

    /// The newest messages that match `text`, scanned off the main actor. A query that asks for
    /// nothing finds nothing.
    public func search(_ text: String) async -> SearchFound {
        let query = LocalSearch.parse(text)
        guard !query.isEmpty else { return .none }
        let users = self.users.userIDs.compactMap { self.users.user($0).flatMap(UserObject.init) }
        let rooms = kept.roomIDs.compactMap { id in kept.room(id).map { SearchContext.Room(id: id, title: title(of: id), parentRoomID: $0.parentRoomID) } }
        let kept = self.kept
        return await Task.detached {
            let context = SearchContext(users: users, rooms: rooms, parentOf: { kept.room($0)?.parentRoomID })
            guard let matches = LocalSearch.matcher(query, in: context) else { return .none }
            let found = LocalSearch.newestMatches([kept.allMessages.filter(matches)])
            return SearchFound(messages: found.messages, more: found.more, query: query)
        }.value
    }

    /// A found message's row.
    public func hit(_ message: MessageSnapshot, in found: SearchFound) -> SearchHit {
        let room = title(of: message.roomID)
        let place = kept.room(message.roomID)?.parentRoomID.map { "\(room) · \(title(of: $0))" } ?? room
        return SearchHit(message: message, place: place, who: displayName(for: message.from),
                         parts: LocalSearch.snippet(MessageText.plain(message.body), found: found.query.text))
    }

    /// The rooms and threads whose title or id holds `text`, in any case and with or without
    /// accents: those it names exactly, then those starting with it, then the rest, each by title.
    public func rooms(named text: String) -> [RoomSuggestion] {
        let wanted = LocalSearch.folded(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !wanted.isEmpty else { return [] }
        let ranked = roomSuggestions.compactMap { room -> (RoomSuggestion, Int)? in
            let keys = [LocalSearch.folded(room.title), LocalSearch.folded(room.id)]
            if keys.contains(wanted) { return (room, 0) }
            if keys.contains(where: { $0.hasPrefix(wanted) }) { return (room, 1) }
            if keys.contains(where: { $0.contains(wanted) }) { return (room, 2) }
            return nil
        }
        return ranked.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            let byTitle = lhs.0.title.localizedCompare(rhs.0.title)
            return byTitle == .orderedSame ? codePointLess(lhs.0.id, rhs.0.id) : byTitle == .orderedAscending
        }.map(\.0)
    }
}
