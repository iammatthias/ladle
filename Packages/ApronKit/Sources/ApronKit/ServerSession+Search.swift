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

/// Load More from Server under a search's results (apron-web #220): what it says, and whether
/// pressing it has anything left to load.
public struct SearchLoadOffer: Equatable, Sendable {
    public var note: String
    /// Everything the server has in the rooms searched is loaded: the button goes.
    public var done: Bool
    public var busy: Bool
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

    /// The most rooms one Load More from Server pages back in, the most recently active first.
    static let searchLoadRooms = 10

    /// The rooms a search looks through: those `room:` names (by id or title), with their
    /// threads, among the rooms joined or opened; else every room and thread joined.
    func searchedRooms(_ query: SearchQuery) -> [String] {
        guard !query.rooms.isEmpty else { return joinedRoomIDs.sorted(by: codePointLess) }
        let shown = store.roomIDs.filter { joinedRoomIDs.contains($0) || histories[$0] != nil }
        let named = Set(shown.filter { query.rooms.contains(LocalSearch.folded($0)) || query.rooms.contains(LocalSearch.folded(title(of: $0))) })
        return shown.filter { named.contains($0) || store.room($0)?.parentRoomID.map(named.contains) == true }.sorted(by: codePointLess)
    }

    /// Of those, the ones the server has older history for: never opened, with a hole between
    /// loaded spans (Ladle's jumps leave them, the web's never), or with older pages; and not
    /// loading one now.
    func searchedRoomsWithOlder(_ query: SearchQuery) -> [String] {
        searchedRooms(query).filter { roomID in
            guard server?.has("history") == true else { return false }
            guard let history = histories[roomID] else { return true }
            return history.loading == nil && (!history.coverage.holes.isEmpty || canLoadOlder(roomID))
        }
    }

    /// What Load More from Server says under a search for `text`; nil where it has nothing to
    /// search (no words, no filter) or no room to page in. `error` is the last press's failure.
    public func searchLoadOffer(for text: String, loading: Bool, error: String?) -> SearchLoadOffer? {
        let query = LocalSearch.parse(text)
        let searched = searchedRooms(query)
        guard !query.isEmpty, !searched.isEmpty else { return nil }
        let place = query.rooms.isEmpty ? "your rooms"
            : title(of: searched.first { store.room($0)?.parentRoomID == nil } ?? searched[0])
        let done = !loading && searchedRoomsWithOlder(query).isEmpty
        let note = error ?? (done ? "Everything the server has in \(place) is loaded, and searched." : "Older messages in \(place) are on the server.")
        return SearchLoadOffer(note: note, done: done, busy: loading)
    }

    /// Load More from Server: a page further back in each of the ten most recently active rooms
    /// searched that have one, all at once: a room never opened loads its newest page, one with
    /// a hole fills its newest hole down from above, so older goes on back from the newest. Returns
    /// the words to show when every page failed, else nil; search again after it.
    public func loadMoreForSearch(_ text: String) async -> String? {
        let rooms = searchedRoomsWithOlder(LocalSearch.parse(text))
            .sorted { lhs, rhs in
                switch (store.latestLogID(of: lhs), store.latestLogID(of: rhs)) {
                case let (l?, r?): l == r ? codePointLess(lhs, rhs) : l > r
                case (.some, nil): true
                case (nil, .some): false
                case (nil, nil): codePointLess(lhs, rhs)
                }
            }
            .prefix(Self.searchLoadRooms)
        guard !rooms.isEmpty else { return nil }
        let pages = rooms.map { roomID in
            let opened = histories[roomID] != nil
            return Task { () -> String? in
                do {
                    if !opened {
                        try await open(roomID)
                    } else if let hole = holes(in: roomID).last {
                        try await fill(hole, in: roomID, .olderFromAbove)
                    } else {
                        try await loadOlder(roomID)
                    }
                    return nil
                } catch {
                    return errorText(error)
                }
            }
        }
        var failures: [String] = []
        for page in pages { if let failure = await page.value { failures.append(failure) } }
        guard failures.count == rooms.count, let first = failures.first else { return nil }
        return "The server didn’t send them: \(first)"
    }
}
