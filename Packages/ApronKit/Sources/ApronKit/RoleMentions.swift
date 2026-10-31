import Foundation

/// A role an `@` can name (`@&role`), as apron-web's `RoleSuggestion` (#181): the room's members
/// other than you who hold it (§3.3.4), in the order the room lists them. Roles are labels only,
/// so `@&role` is the composer's shorthand for mentioning each of them: the message lists them
/// one by one in `body.mentions` (§3.5.5), and the server never reads the text.
public struct RoleSuggestion: Hashable, Sendable {
    public var role: String
    public var members: [String]

    public init(role: String, members: [String]) {
        self.role = role
        self.members = members
    }
}

/// `@&role` in text, as apron-web's `role-mentions.ts` and `markdown.ts` read and write it.
public enum RoleMentions {
    /// At most this many of the `@` list's places go to roles when people fill it, after anyone
    /// named exactly (apron-web's `ROLE_MATCHES_MAX`).
    public static let placesKept = 3

    /// Whether a role can be written `@&role`: it reads whole as one ID (Appendix A.3), so a role
    /// with a space is left out.
    public static func isMentionable(_ role: String) -> Bool {
        whole.firstMatch(in: role, range: NSRange(role.startIndex..., in: role)) != nil
    }

    /// The roles held by anyone in `people` but `you`, each with who holds it, most held first,
    /// then by name, as apron-web's `roomRoles`.
    public static func roles(of people: [UserObject], you: String?, roles: (UserObject) -> [String]) -> [RoleSuggestion] {
        var order: [String] = []
        var holders: [String: [String]] = [:]
        for person in people where person.userID != you {
            var seen = Set<String>()
            for role in roles(person) where isMentionable(role) && seen.insert(role).inserted {
                if holders[role] == nil { order.append(role) }
                holders[role, default: []].append(person.userID)
            }
        }
        return order.map { RoleSuggestion(role: $0, members: holders[$0] ?? []) }.sorted { lhs, rhs in
            if lhs.members.count != rhs.members.count { return lhs.members.count > rhs.members.count }
            return lhs.role.localizedCompare(rhs.role) == .orderedAscending
        }
    }

    /// Roles whose name starts with `query` (a leading `&` asks for roles alone), the one it
    /// names exactly first, as apron-web's `searchRoles`. A space typed after the name matches
    /// only the role it names exactly.
    public static func search(_ roles: [RoleSuggestion], _ query: String) -> [RoleSuggestion] {
        let needle = (query.hasPrefix("&") ? String(query.dropFirst()) : query).lowercased()
        let exact = needle.replacing(/\s+$/, with: "")
        let exactFirst = roles.filter { !exact.isEmpty && $0.role.lowercased() == exact }
        let starting = roles.filter { $0.role.lowercased().hasPrefix(needle) && !exactFirst.contains($0) }
        return exactFirst + starting
    }

    /// Each `@&role` written in `text`, not right after a letter or digit, with where its `@`
    /// stands (in unicode scalars) and how long it is, in order. The role is the longest ID that
    /// follows (Appendix A.3), whether or not anyone holds it.
    public static func written(in text: String) -> [(offset: Int, length: Int, role: String)] {
        reference.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let whole = Range(match.range, in: text), let role = Range(match.range(at: 1), in: text) else { return nil }
            return (text.unicodeScalars.distance(from: text.startIndex, to: whole.lowerBound), text[whole].unicodeScalars.count, String(text[role]))
        }
    }

    /// apron-web's `TEXT_ID`, whole.
    private static let whole = try! NSRegularExpression(pattern: #"^[A-Za-z0-9_](?:[A-Za-z0-9_.+@:-]*[A-Za-z0-9_])?$"#)
    /// `@&` not after a letter or digit, then a `TEXT_ID` (apron-web's `MENTION`, its first branch).
    static let reference = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9])@&([A-Za-z0-9_](?:[A-Za-z0-9_.+@:-]*[A-Za-z0-9_])?)"#)
}

/// Marks a role mention in rendered text (`MessageText`); the value is the role. The run reads
/// `@role`, and opens nothing: it describes the text and names no one.
public enum RoleMentionKey: AttributedStringKey {
    public typealias Value = String
    public static let name = "ApronRoleMention"
}

/// One row of the composer's `@` list: a person, or a role that mentions everyone else here
/// who holds it.
public enum MentionSuggestion: Hashable, Sendable {
    case person(UserObject)
    case role(RoleSuggestion)
}

extension ServerSession {
    /// The roles an `@` can name in `roomID`: held by its members other than you, from each
    /// one's latest roles.
    public func mentionableRoles(in roomID: String) -> [RoleSuggestion] {
        RoleMentions.roles(of: memberSections(roomID).flatMap(\.people), you: you?.userID, roles: roles(of:))
    }
}
