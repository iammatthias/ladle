/// One kept user object per `user_id` (§3.3.1). Complete objects replace; other current objects
/// merge field by field, with an empty value clearing the field. Recorded objects, such as a
/// message's `from`, are never kept; they are the fallback for fields the kept object lacks.
public struct UserDirectory: Hashable, Sendable {
    private var kept: [String: [String: JSONValue]] = [:]

    public init() {}

    public mutating func replace(with complete: UserObject) {
        kept[complete.userID] = complete.json.objectValue ?? [:]
    }

    public mutating func merge(_ current: UserObject) {
        var fields = kept[current.userID] ?? ["user_id": .string(current.userID)]
        for (key, value) in current.json.objectValue ?? [:] {
            if value.isEmptyValue { fields[key] = nil } else { fields[key] = value }
        }
        kept[current.userID] = fields
    }

    public func user(_ userID: String) -> JSONValue? {
        kept[userID].map(JSONValue.object)
    }

    /// The name to show: the kept `name`, else the recorded one, else the `user_id`, without
    /// bidirectional overrides (§3.5.2). Shown as `Name (@user_id)`, the name isolated, when
    /// another known user has the same name (§3.3.1).
    public func displayName(for user: UserObject) -> String {
        let name = name(of: user.userID, recorded: user.json)
        guard let name else { return TextDirection.withoutOverrides(user.userID) }
        let clash = kept.contains { userID, fields in
            userID != user.userID && fields["name"]?.stringValue == name
        }
        return clash ? "\(TextDirection.isolated(name)) (@\(user.userID))" : TextDirection.withoutOverrides(name)
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
