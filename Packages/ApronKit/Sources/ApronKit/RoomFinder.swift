import Foundation

/// Finding rooms and threads by name, as apron-web's `room-match.ts` and `room-search.ts` (#220):
/// Search's rooms and threads, the composer's `#` list and Search Rooms share `tier`. What it
/// searches is what this device knows of (`known`): the rooms and threads the session holds a
/// record of (joined ones, those read without joining, those the latest listings offered), then
/// those whose records the device keeps. Joined ones come first, then how well each matches,
/// then the most recently active.
public enum RoomFinder {
    /// How well a name matches, best first: the whole of it, its start, the start of a word in
    /// its title, anywhere in it, its description.
    public enum Tier: Int, Comparable, Sendable {
        case whole, start, word, anywhere, description
        public static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public struct KnownRoom: Hashable, Sendable {
        public var id: String
        public var title: String
        public var parentRoomID: String?
        public var description: String?
        public var isPrivate = false
        public var joined: Bool
        /// Its latest activity known here, for the order.
        public var activeID: LogID?

        public init(id: String, title: String, parentRoomID: String? = nil, description: String? = nil,
                    isPrivate: Bool = false, joined: Bool, activeID: LogID? = nil) {
            self.id = id
            self.title = title
            self.parentRoomID = parentRoomID
            self.description = description
            self.isPrivate = isPrivate
            self.joined = joined
            self.activeID = activeID
        }

        public var isThread: Bool { parentRoomID != nil }
    }

    public struct Found: Hashable, Sendable {
        public var room: KnownRoom
        public var tier: Tier
    }

    /// What a search found: the first `limit`, in order, how many matched in all, and the rooms
    /// `room:` named that are known, whose threads were what was searched.
    public struct Results: Hashable, Sendable {
        public var rooms: [Found]
        public var total: Int
        public var scope: [KnownRoom]
    }

    /// Where the listing of the threads of the room `room:` names is (apron-web #224's
    /// `RoomFinder.foot`): under way, done with how many the server listed, or refused and why.
    public enum ThreadsListing: Hashable, Sendable {
        case listing
        case listed(Int)
        case failed(String)

        /// The line after the results, for the room titled `title`.
        public func note(title: String) -> String {
            switch self {
            case .listing: "Listing \(title)’s other threads…"
            case .failed(let error): "\(title)’s other threads didn’t list: \(error)"
            case .listed(0): "No threads you haven’t joined, as the server lists them."
            case .listed(let count): "Threads you haven’t joined: the \(count == 1 ? "one" : String(count)) the server lists, its most recently active."
            }
        }

        /// Try Again, after a listing failed.
        public var failed: Bool { if case .failed = self { true } else { false } }
    }

    /// The most a search lists, as apron-web's `ROOM_SEARCH_LIMIT`.
    public static let limit = 50

    /// What separates the words of a title, as apron-web's `WORD_BREAK`.
    private static let wordBreaks: Set<Character> = [" ", "\t", "\n", "-", "_", ".", ",", ":", ";", "/", "(", ")", "[", "]", "#", "@", "&", "+", "|"]

    /// What is typed, as a match wants it: folded, trimmed, without a leading `#`.
    public static func wanted(_ typed: String) -> String {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return LocalSearch.folded(trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed)
    }

    /// How a room with `id`, `title` and `description` matches `wanted` (already `wanted(_:)`), or
    /// nil; the description counts only with `described`.
    public static func tier(id: String, title: String, description: String? = nil, _ wanted: String, described: Bool = false) -> Tier? {
        guard !wanted.isEmpty else { return .whole }
        let title = LocalSearch.folded(title.trimmingCharacters(in: .whitespacesAndNewlines)), id = LocalSearch.folded(id)
        if title == wanted || id == wanted { return .whole }
        if title.hasPrefix(wanted) || id.hasPrefix(wanted) { return .start }
        var rest = title[...]
        while let found = rest.range(of: wanted) {
            if found.lowerBound > title.startIndex, wordBreaks.contains(title[title.index(before: found.lowerBound)]) { return .word }
            rest = title[title.index(after: found.lowerBound)...]
        }
        if title.contains(wanted) || id.contains(wanted) { return .anywhere }
        if described, let description, LocalSearch.folded(description).contains(wanted) { return .description }
        return nil
    }

    /// Every room and thread known, each once: as the session holds it (`live`), else from a
    /// record the device keeps, leaving out a private room known only from a record (one you
    /// left), which can't be read without being a member again.
    public static func known(_ live: [KnownRoom], records: [RoomRecord]) -> [KnownRoom] {
        var seen = Set(live.map(\.id))
        var known = live
        for record in records where record.isPrivate != true && !seen.contains(record.roomID) {
            seen.insert(record.roomID)
            let title = record.title?.stringValue.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? record.roomID
            let description = record.description?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            known.append(KnownRoom(id: record.roomID, title: title, parentRoomID: record.parentRoomID, description: description,
                                   joined: false, activeID: record.logID))
        }
        return known
    }

    /// The rooms in `known` that `text` finds: joined first, then by `tier` (the description
    /// too), then the most recently active, then by title. With `rooms` (`room:`'s values,
    /// folded), only the threads of the top-level rooms they name by id or title; with nothing
    /// typed, every room, or every thread of those.
    public static func rank(_ known: [KnownRoom], text: String, rooms: [String] = [], limit: Int = limit) -> Results {
        let wanted = wanted(text)
        let scope = rooms.isEmpty ? [] : known.filter { room in
            room.parentRoomID == nil && rooms.contains { LocalSearch.folded(room.id) == $0 || LocalSearch.folded(room.title.trimmingCharacters(in: .whitespaces)) == $0 }
        }
        let parents = Set(scope.map(\.id))
        var found: [Found] = []
        for room in known {
            if !rooms.isEmpty, !(room.parentRoomID.map(parents.contains) ?? false) { continue }
            if let tier = tier(id: room.id, title: room.title, description: room.description, wanted, described: true) {
                found.append(Found(room: room, tier: tier))
            }
        }
        found.sort { a, b in
            if a.room.joined != b.room.joined { return a.room.joined }
            if a.tier != b.tier { return a.tier < b.tier }
            if a.room.activeID != b.room.activeID {
                guard let left = a.room.activeID else { return false }
                guard let right = b.room.activeID else { return true }
                return left > right
            }
            let byTitle = a.room.title.compare(b.room.title, options: [.caseInsensitive, .diacriticInsensitive])
            if byTitle != .orderedSame { return byTitle == .orderedAscending }
            return codePointLess(a.room.id, b.room.id)
        }
        return Results(rooms: Array(found.prefix(limit)), total: found.count, scope: scope)
    }
}

extension ServerSession {
    /// The rooms and threads search finds by name (`RoomFinder.known`).
    public var knownRooms: [RoomFinder.KnownRoom] {
        let live = store.roomIDs.compactMap { id -> RoomFinder.KnownRoom? in
            guard let record = store.room(id) else { return nil }
            let joined = joinedRoomIDs.contains(id)
            if record.isPrivate == true, !joined { return nil }
            return RoomFinder.KnownRoom(id: id, title: title(of: id), parentRoomID: record.parentRoomID, description: roomDescription(id),
                                        isPrivate: record.isPrivate == true, joined: joined, activeID: activity(of: id))
        }
        return RoomFinder.known(live, records: kept.roomIDs.compactMap { kept.room($0) })
    }
}
