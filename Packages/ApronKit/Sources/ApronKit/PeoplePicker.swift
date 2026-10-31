import Foundation

/// Picking people, as apron-web's PeoplePicker serves New private conversation and Add people:
/// everyone the session knows but you and the system identities, by name, narrowed by what is
/// typed, and the picked ones as chips in order.
public struct PeoplePicker: Hashable, Sendable {
    /// The most people listed at once: typing narrows it.
    public static let shown = 50

    /// What's typed in the field.
    public var query = ""
    /// The `user_id`s picked, in order.
    public private(set) var chosen: [String] = []

    public init() {}

    /// Picks someone, or unpicks them when they are picked already.
    public mutating func toggle(_ userID: String) {
        if let index = chosen.firstIndex(of: userID) { chosen.remove(at: index) } else { chosen.append(userID) }
    }

    public mutating func keep(_ userIDs: [String]) { chosen = userIDs }

    /// The `user_id` typed to add someone, as apron-web's `userIdToAdd`: exactly that ID, bare or
    /// as `@user_id`. Display names are never looked up, since they aren't unique (§3.3): adding
    /// by name could add an impersonator. Nil when the text can't be an ID (§2.4).
    public static func userID(typed: String) -> String? {
        var id = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.hasPrefix("@") { id.removeFirst() }
        guard !id.isEmpty, !id.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.properties.generalCategory == .control }) else { return nil }
        return id
    }
}

/// One row of the picker.
public struct PickPerson: Hashable, Sendable, Identifiable {
    public let userID: String
    public let name: String
    /// You already talk to them: alone, a tap opens that conversation ("Already talking · Open").
    public let existing: Bool
    /// Not someone the session knows: added by the `@user_id` typed.
    public let typed: Bool
    public var id: String { userID }
}

extension ServerSession {
    /// Everyone the session knows who could be picked, but you, the system identities (`~`) and
    /// `excluded`, by name, then by `user_id`.
    public func pickable(excluding excluded: Set<String> = []) -> [UserObject] {
        users.userIDs.compactMap { users.user($0).flatMap(UserObject.init) }
            .filter { !isYou($0.userID) && !$0.userID.hasPrefix("~") && !excluded.contains($0.userID) }
            .sorted { a, b in
                let x = users.plainName(for: a), y = users.plainName(for: b)
                return x == y ? codePointLess(a.userID, b.userID) : PeopleTitle.byName(x, y)
            }
    }

    /// Those of `people` whose name or `user_id` holds what's typed (a leading `@` aside, any
    /// case), at most `PeoplePicker.shown`.
    public func matching(_ people: [UserObject], _ typed: String) -> [UserObject] {
        var wanted = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if wanted.hasPrefix("@") { wanted.removeFirst() }
        let found = wanted.isEmpty ? people : people.filter {
            users.plainName(for: $0).lowercased().contains(wanted) || $0.userID.lowercased().contains(wanted)
        }
        return Array(found.prefix(PeoplePicker.shown))
    }

    /// New private conversation's rows: who matches, each saying whether you already talk to them.
    public func privatePeople(_ picker: PeoplePicker) -> [PickPerson] {
        matching(pickable(), picker.query).map { person in
            PickPerson(userID: person.userID, name: users.plainName(for: person), existing: directRoom(with: person.userID) != nil, typed: false)
        }
    }

    /// Add people's rows: those who aren't members of the room yet who match, or with none, the
    /// `@user_id` typed, since the session knows only some of the server's users.
    public func addablePeople(_ picker: PeoplePicker, to roomID: String) -> [PickPerson] {
        let members = Set((store.members(of: roomID) ?? []).map { users.current($0.userID) })
        let shown = matching(pickable(excluding: members), picker.query).map {
            PickPerson(userID: $0.userID, name: users.plainName(for: $0), existing: false, typed: false)
        }
        guard shown.isEmpty, let typed = PeoplePicker.userID(typed: picker.query), !members.contains(typed), !typed.hasPrefix("~"), !isYou(typed) else { return shown }
        return [PickPerson(userID: typed, name: typed, existing: false, typed: true)]
    }

    /// A picked person's name for a chip, known or not.
    public func pickedName(_ userID: String) -> String {
        users.plainName(for: UserObject(["user_id": .string(userID)])!)
    }

    /// New private conversation's button, short for a navigation bar (the web's "Message Ada" and
    /// "Start conversation"; the chips say who): "Message" for one, "Start" for more, "Starting…".
    public static func startWords(chosen: [String], saving: Bool) -> String {
        if saving { return "Starting…" }
        return chosen.count == 1 ? "Message" : "Start"
    }
}
