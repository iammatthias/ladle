import Foundation

/// One membership record (§4.2.2): who joined or left a room at one log position. An add by
/// someone else (`room_join` with a `user_id`) is a join, as apron-web #170 shows it.
public struct MembershipRecord: Hashable, Sendable {
    public struct Entry: Hashable, Sendable {
        public var user: UserObject
        public var joined: Bool
    }

    public var logID: LogID
    public var entries: [Entry]

    /// apron-web's `isBaseline`: a record that joins `MembershipLines.baselineMin` users or more
    /// at once is the compacted list of every member a server logs before it discards history,
    /// not something that happened, so it gets no line.
    public var isBaseline: Bool {
        entries.count >= MembershipLines.baselineMin && entries.allSatisfy(\.joined)
    }
}

/// A room record whose title differs from the one logged before it: "Room renamed to “Ops”".
public struct RoomRename: Hashable, Sendable {
    public var logID: LogID
    public var title: String
    public var previous: String
}

/// Join and leave lines, as apron-web's `membership.ts`: consecutive membership records with
/// nothing else between them make one run, netted per user.
public enum MembershipLines {
    public static let baselineMin = 21
    /// How many names a line spells out before it counts the rest.
    static let listed = 3

    /// Who a run comes to, in the order each user first appears in it, as apron-web's
    /// `MembershipRun.net`: a user's state after the run against before it, which their first
    /// entry implies (a join means they were out). Someone who joins and leaves within the run,
    /// or leaves and comes back, is in neither list. Each is their latest object in the run.
    public static func net(_ records: [MembershipRecord]) -> (joined: [UserObject], left: [UserObject]) {
        var order: [String] = []
        var users: [String: (first: Bool, last: Bool, user: UserObject)] = [:]
        for entry in records.flatMap(\.entries) {
            let id = entry.user.userID
            if let current = users[id] {
                users[id] = (current.first, entry.joined, entry.user)
            } else {
                order.append(id)
                users[id] = (entry.joined, entry.joined, entry.user)
            }
        }
        var joined: [UserObject] = [], left: [UserObject] = []
        for id in order {
            guard let state = users[id], state.first == state.last else { continue }
            if state.last { joined.append(state.user) } else { left.append(state.user) }
        }
        return (joined, left)
    }

    /// Names as a line says them: "Ada", "Ada and Bob", "Ada, Bob, and Carol", and past three
    /// the first two and a count: "Ada, Bob, and 4 others".
    public static func list(_ names: [String]) -> String {
        let shown = names.count <= listed ? names : [names[0], names[1], "\(names.count - 2) others"]
        switch shown.count {
        case 0: return ""
        case 1: return shown[0]
        case 2: return "\(shown[0]) and \(shown[1])"
        default: return shown.dropLast().joined(separator: ", ") + ", and " + shown[shown.count - 1]
        }
    }

    /// A run's line, "Ada and Bob joined · Carol left", and, when it had to count some names,
    /// every name ("Joined: Ada, Bob, Carol, Dev\nLeft: Eun-ji"), which VoiceOver reads.
    public static func summary(joined: [String], left: [String]) -> (text: String, full: String?) {
        var parts: [String] = []
        if !joined.isEmpty { parts.append("\(list(joined)) joined") }
        if !left.isEmpty { parts.append("\(list(left)) left") }
        let text = parts.joined(separator: " · ")
        guard joined.count > listed || left.count > listed else { return (text, nil) }
        var full: [String] = []
        if !joined.isEmpty { full.append("Joined: " + joined.joined(separator: ", ")) }
        if !left.isEmpty { full.append("Left: " + left.joined(separator: ", ")) }
        return (text, full.joined(separator: "\n"))
    }

    /// A rename's line: "Room renamed to “Ops”", or "Thread name cleared" for an emptied title.
    public static func rename(_ title: String, thread: Bool) -> String {
        let what = thread ? "Thread" : "Room"
        let shown = TextDirection.withoutOverrides(title)
        return shown.isEmpty ? "\(what) name cleared" : "\(what) renamed to “\(shown)”"
    }
}
