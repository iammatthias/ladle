import Foundation

/// What a person's profile card shows, as apron-web's ProfileCard: who they are, how they show
/// now, what they wrote about themselves, whether they are in the open room, and what you can do
/// about them here. Worked out once, from the session.
public struct UserProfile: Hashable, Sendable {
    public let userID: String
    /// Their name alone; `sharesName` says when the `@user_id` must be read with it (§3.3.1).
    public let name: String
    public let isYou: Bool
    public let sharesName: Bool
    /// Their dot: the shown status, or your chosen one.
    public let presence: Presence?
    /// The status in words (`Presence.words`), nil for none.
    public let status: String?
    /// "Last seen 3h ago", while they show offline (§4.5.2); never yours.
    public let lastSeen: String?
    public let roles: [String]
    /// Their bio, on a server that keeps one (`ext:bio`).
    public let bio: String?
    /// "Member of General" or "Not in General", when the room's members are known.
    public let membership: String?
    /// Mention puts `@name` in the composer: the composer takes text, and they are not a system
    /// identity (`~`).
    public let mayMention: Bool
    /// Add to room (§4.2.2, `room_join` with `user_id`), as apron-web offers it.
    public let mayAddToRoom: Bool
    /// Message opens the private conversation you have with them, or starts one (`message(_:)`).
    public let mayMessage: Bool
}

extension ServerSession {
    /// The profile card of `user` (a kept user, a message's `from`, a member), as seen from
    /// `roomID`, the open room or thread, when there is one.
    public func profile(of user: UserObject, in roomID: String?, now: Date = .now, calendar: Calendar = .current) -> UserProfile {
        let id = users.current(user.userID)
        let kept = users.user(id) ?? user.json
        let yours = isYou(id)
        let shown = yours ? chosenStatus : kept["status"]?.stringValue
        let system = id.hasPrefix("~")
        let members = roomID.flatMap { store.members(of: $0) }
        let listed = members?.contains { users.current($0.userID) == id }
        let membership: String? = switch (roomID, listed) {
        case (let roomID?, true?): "Member of \(title(of: roomID))"
        case (let roomID?, false?): "Not in \(title(of: roomID))"
        default: nil
        }
        let mayAdd: Bool = {
            guard let roomID, listed == false, !yours, !system, status == .signedIn, mayWrite,
                  server?.has("rooms") == true, joinedRoomIDs.contains(roomID) else { return false }
            return permissions.addMembers || isPrivate(roomID)
        }()
        return UserProfile(
            userID: id,
            name: users.plainName(for: user),
            isYou: yours,
            sharesName: users.sharesName(user),
            presence: Presence(status: shown),
            status: Presence.words(shown, yours: yours),
            lastSeen: yours || shown != "offline" ? nil : LastSeen.text(kept["seen"]?.stringValue, now: now, calendar: calendar),
            roles: UserObject(kept)?.roles ?? user.roles,
            bio: keepsBio ? Bio.of(kept) : nil,
            membership: membership,
            mayMention: roomID != nil && mayWrite && status == .signedIn && !system,
            mayAddToRoom: mayAdd,
            mayMessage: mayStartPrivate && !yours && !system
        )
    }

    /// Adds someone to a room (§4.2.2): `room_join` with their `user_id`.
    public func addMember(_ userID: String, to roomID: String) async throws {
        try require("rooms")
        _ = try await request("room_join", ["room_id": .string(roomID), "user_id": .string(userID)])
    }
}

/// When someone was last seen (§4.5.2), in words, as apron-web's `lastSeen`.
public enum LastSeen {
    /// Under this long ago, "recently": a server may record `seen` coarsely.
    static let recent: TimeInterval = 10 * 60
    /// How far ahead a `seen` from a clock that differs may be and still read as recent.
    static let skew: TimeInterval = 5 * 60
    /// How far back the words count in minutes, hours and days before naming the day.
    static let window: TimeInterval = 14 * 24 * 3600

    /// "Last seen recently" under ten minutes ago, then "Last seen 15m ago", "3h ago" or
    /// "12d ago" within two weeks, then the day ("Last seen Sep 14", with the year when it is
    /// not this one's). Nil without a `seen` in the `log_id` format.
    public static func text(_ seen: String?, now: Date, calendar: Calendar = .current) -> String? {
        guard let seen, seen.wholeMatch(of: /[1-9][0-9]{0,15}/) != nil, let millis = Double(seen) else { return nil }
        let date = Date(timeIntervalSince1970: millis / 1000)
        let elapsed = now.timeIntervalSince(date)
        let ahead = -elapsed > skew
        if !ahead, elapsed < recent { return "Last seen recently" }
        if !ahead, elapsed < window {
            let minutes = Int(elapsed / 60), hours = minutes / 60
            let since = hours < 1 ? "\(minutes)m" : hours < 24 ? "\(hours)h" : "\(hours / 24)d"
            return "Last seen \(since) ago"
        }
        var style = Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated).day()
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) { style = style.year() }
        return "Last seen \(date.formatted(style))"
    }
}
