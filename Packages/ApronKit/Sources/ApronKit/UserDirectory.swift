/// One kept user object per `user_id` (§3.3.1). Complete objects replace; other current objects
/// merge field by field, with an empty value clearing the field. Recorded objects, such as a
/// message's `from`, are never kept; they are the fallback for fields the kept object lacks.
public struct UserDirectory: Hashable, Sendable {
    private var kept: [String: [String: JSONValue]] = [:]
    private var renamed: [String: String] = [:]

    public init() {}

    /// The `user_id` an account has now: the one given unless an account changed it (§3.3.3).
    public func current(_ userID: String) -> String {
        var id = userID
        for _ in 0 ..< renamed.count + 1 {
            guard let next = renamed[id] else { return id }
            id = next
        }
        return id
    }

    /// An account changed its `user_id` from `old` to `new` (§3.3.3): the kept object moves to
    /// `new`, beneath whatever `new` already has, and `old` reads as `new` from then on, so the
    /// records logged under `old` show the account's current name.
    public mutating func rename(from old: String, to new: String) {
        let old = current(old), new = current(new)
        guard old != new else { return }
        if let moved = kept.removeValue(forKey: old) {
            var fields = moved
            for (key, value) in kept[new] ?? [:] { fields[key] = value }
            fields["user_id"] = .string(new)
            kept[new] = fields
        }
        for (alias, target) in renamed where target == old { renamed[alias] = new }
        renamed[old] = new
    }

    public mutating func replace(with complete: UserObject) {
        kept[complete.userID] = complete.json.objectValue ?? [:]
    }

    public mutating func merge(_ current: UserObject) {
        let id = self.current(current.userID)
        var fields = kept[id] ?? ["user_id": .string(id)]
        for (key, value) in current.json.objectValue ?? [:] where key != "user_id" {
            if value.isEmptyValue { fields[key] = nil } else { fields[key] = value }
        }
        kept[id] = fields
    }

    public func user(_ userID: String) -> JSONValue? {
        kept[current(userID)].map(JSONValue.object)
    }

    /// The name to show: the kept `name`, else the recorded one, else the `user_id`, without
    /// bidirectional overrides (§3.5.2). Shown as `Name (@user_id)`, the name isolated, when
    /// another known user has the same name (§3.3.1).
    public func displayName(for user: UserObject) -> String {
        let id = current(user.userID)
        let name = name(of: id, recorded: user.json)
        guard let name else { return TextDirection.withoutOverrides(id) }
        let clash = kept.contains { userID, fields in
            userID != id && fields["name"]?.stringValue == name
        }
        return clash ? "\(TextDirection.isolated(name)) (@\(id))" : TextDirection.withoutOverrides(name)
    }

    private func name(of userID: String, recorded: JSONValue) -> String? {
        let name = kept[userID]?["name"]?.stringValue ?? recorded["name"]?.stringValue
        guard let name, !name.isEmpty else { return nil }
        return name
    }
}

extension JSONValue {
    /// `""`, `[]`, or `{}`: the value that clears a field when a current object merges (§3.3.1).
    var isEmptyValue: Bool {
        switch self {
        case .string(let text): text.isEmpty
        case .array(let elements): elements.isEmpty
        case .object(let members): members.isEmpty
        default: false
        }
    }
}
